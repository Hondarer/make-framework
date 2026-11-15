#!/usr/bin/env pwsh
# 診断の帰属、既存行清掃、実際の /MP と部分再コンパイルを確認する。
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../bin_internal/_msvc_utils.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ('makefw warnings ' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$originalDirectory = [Environment]::CurrentDirectory
$compileScript = (Resolve-Path "$PSScriptRoot/../bin_internal/msvc_compile.ps1").Path
$utf8 = Get-Utf8NoBomEncoding
Push-Location $root
[Environment]::CurrentDirectory = $root
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    Write-Host "PASS: $Message"
}
try {
    foreach ($name in 'a.c', 'b.c', 'shared.h') { [IO.File]::WriteAllText("$root/$name", '', $utf8) }
    $sources = @('a.c', 'b.c')
    $includes = @{ 'a.c' = @("$root/shared.h"); 'b.c' = @("$root/shared.h") }
    $own = "$root/a.c(3): warning C4100: own"
    $shared = "$root/shared.h(2): warning C4100: shared"
    $command = 'cl : Command line warning D9002: ignored option'
    # ソース名の表示順には依存せず、診断のパスだけで割り当てる。
    $warnings = Get-MsvcWarningMap -Sources $sources -Includes $includes -DependenciesComplete $true -Diagnostics @($own, $shared, $command)
    Assert-Test ($warnings['a.c'].Count -eq 3 -and $warnings['b.c'].Count -eq 2) 'own path, shared header and command-line warning ownership'
    $warnings = Get-MsvcWarningMap -Sources $sources -Includes $includes -DependenciesComplete $false -Diagnostics @($own, $shared)
    Assert-Test ($warnings['a.c'].Count -eq 2 -and $warnings['b.c'].Count -eq 1) 'incomplete dependency information preserves diagnostics'
    $mixedPath = $own.Replace('/', '\').ToUpperInvariant()
    $warnings = Get-MsvcWarningMap -Sources $sources -Includes $includes -DependenciesComplete $true -Diagnostics @($mixedPath)
    Assert-Test ($warnings['a.c'].Count -eq 1 -and $warnings['b.c'].Count -eq 0) 'case and path separators normalize'
    $shortSource = (& cygpath -s -m "$root/a.c").Trim()
    Assert-Test ($LASTEXITCODE -eq 0) 'short path conversion is available'
    $shortDiagnostic = "${shortSource}(1): warning C4100: short path"
    $warnings = Get-MsvcWarningMap -Sources $sources -Includes $includes -DependenciesComplete $true -Diagnostics @($shortDiagnostic)
    Assert-Test ($warnings['a.c'].Count -eq 1 -and $warnings['b.c'].Count -eq 0) 'short and long source paths match'
    $other = "$root/other.c(1): warning C4100: other"
    [IO.File]::WriteAllLines("$root/b.c.warn", @($own, $shared, $other, $command), $utf8)
    [IO.File]::WriteAllLines("$root/orphan.c.warn", @($own), $utf8)
    $warnings = Get-MsvcWarningMap -Sources @('a.c') -Includes @{} -DependenciesComplete $true -Diagnostics @()
    Update-MsvcWarningFiles -Sources @('a.c') -Warnings $warnings
    $kept = [IO.File]::ReadAllLines("$root/b.c.warn", $utf8)
    Assert-Test ($kept.Count -eq 3 -and $kept -notcontains $own -and $kept -contains $shared) 'partial rebuild cleans only recompiled-source diagnostics'
    Assert-Test (-not (Test-Path -LiteralPath "$root/orphan.c.warn")) 'empty stale warning file is removed'
    Assert-Test ((Get-MsvcDiagnosticFile 'not a diagnostic') -eq '') 'unrecognized lines are retained'

    # 実際のコンパイラ出力と JSON を通してラッパー全体を確認する。
    [IO.File]::WriteAllText("$root/shared.h", "#pragma once`nstatic int shared_function(int unused) { return 1; }`n", $utf8)
    [IO.File]::WriteAllText("$root/a.c", "#include `"shared.h`"`nint a(int unused) { return shared_function(0); }`n", $utf8)
    [IO.File]::WriteAllText("$root/b.c", "#include `"shared.h`"`nint b(void) { return shared_function(0); }`n", $utf8)
    & $compileScript -Flags '/nologo /W4 /MP2 /utf-8' -ObjDir obj -Sources 'a.c b.c' -DisablePch
    Assert-Test ($LASTEXITCODE -eq 0) 'real /MP compilation succeeds'
    Assert-Test (([IO.File]::ReadAllText("$root/a.c.warn", $utf8)) -match 'C4100') 'real source warning is saved'
    Assert-Test (([IO.File]::ReadAllText("$root/b.c.warn", $utf8)) -match 'shared.h') 'real shared-header warning is saved'
    Assert-Test (([IO.File]::ReadAllText("$root/a.c.warn", $utf8)) -match 'shared.h') 'shared header warning is preserved for every candidate'
    [IO.File]::WriteAllText("$root/a.c", "int a(void) { return 0; }`n", $utf8)
    [IO.File]::WriteAllText("$root/b.c.warn", "$root/a.c(2): warning C4100: stale`n$other`n", $utf8)
    & $compileScript -Flags '/nologo /W4 /MP2 /utf-8' -ObjDir obj -Sources 'a.c' -DisablePch
    Assert-Test ($LASTEXITCODE -eq 0 -and -not (Test-Path a.c.warn)) 'source fix removes its warning without clean'
    Assert-Test (([IO.File]::ReadAllText("$root/b.c.warn", $utf8)).Trim() -eq $other) 'real partial compile cleans stale misassignment'
    # 失敗時に前回成功した JSON を再利用しない。
    [IO.File]::WriteAllText("$root/a.c", "#error deliberate_compile_failure`n", $utf8)
    & $compileScript -Flags '/nologo /W4 /MP2 /utf-8' -ObjDir obj -Sources 'a.c' -DisablePch
    Assert-Test ($LASTEXITCODE -ne 0) 'compiler failure exit code is preserved'

    # 交錯した出力と破損・欠落 JSON を、ラッパーの実際の読取経路へ渡す。
    $fakeSource = @'
#include <stdio.h>
int main(void) {
    FILE *f = fopen("obj/a.c.json", "w");
    if (!f) return 3;
    fputs("{broken", f);
    fclose(f);
    puts("a.c\nb.c\na.c(2): warning C4100: own after b source name");
    puts("shared.h(1): warning C4100: shared with incomplete dependencies");
    puts("cl : Command line warning D9002: unknown option");
    return 0;
}
'@
    [IO.File]::WriteAllText("$root/fake.c", $fakeSource, $utf8)
    & cl /nologo /D_CRT_SECURE_NO_WARNINGS /Fe:fake.exe fake.c
    Assert-Test ($LASTEXITCODE -eq 0) 'diagnostic fixture compiler builds'
    & $compileScript -Compiler "$root/fake.exe" -ObjDir obj -Sources 'a.c b.c' -DisablePch
    Assert-Test ($LASTEXITCODE -eq 0) 'invalid dependency JSON does not change compiler exit code'
    $aWarnings = [IO.File]::ReadAllText("$root/a.c.warn", $utf8)
    $bWarnings = [IO.File]::ReadAllText("$root/b.c.warn", $utf8)
    Assert-Test ($aWarnings -match 'own after b' -and $bWarnings -notmatch 'own after b') 'interleaved source names cannot redirect source warnings'
    Assert-Test ($aWarnings -match 'shared with incomplete' -and $bWarnings -match 'shared with incomplete') 'invalid and missing JSON preserve shared diagnostic'
    Assert-Test ($aWarnings -match 'D9002' -and $bWarnings -match 'D9002') 'pathless diagnostics are preserved without dependencies'
    Write-Host 'MSVC warning regression tests passed.'
}
finally {
    [Environment]::CurrentDirectory = $originalDirectory
    Pop-Location
    # 削除対象はこのテストで生成した一時ディレクトリだけに限定する。
    $resolvedRoot = [IO.Path]::GetFullPath($root)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolvedRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
