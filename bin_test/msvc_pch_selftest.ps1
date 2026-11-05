# 自動 PCH を実際の MSVC で検証する。一時ワークスペースだけを使用する。
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../bin_internal/_msvc_pch.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ('makefw pch ' + [guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Path $root | Out-Null
$script = (Resolve-Path "$PSScriptRoot/../bin_internal/msvc_compile.ps1").Path
Push-Location $root
$originalDirectory = [Environment]::CurrentDirectory
[Environment]::CurrentDirectory = $root
try {
    [IO.File]::WriteAllText("$root/detail.h", "#pragma once`nstruct Detail { int value; };`n", $utf8)
    [IO.File]::WriteAllText("$root/common.h", "#pragma once`n#include <detail.h>`nstruct Common { int value; };`n", $utf8)
    [IO.File]::WriteAllText("$root/first.cc", "#include <common.h>`nint first() { return sizeof(Common); }`n", $utf8)
    [IO.File]::WriteAllText("$root/second.cc", "#include <common.h>`nint second() { return sizeof(Common); }`n", $utf8)
    [IO.File]::WriteAllText("$root/macro.cc", "#define LOCAL 1`n#include <common.h>`n", $utf8)
    $groups = @(Get-MsvcPchGroups @('first.cc', 'second.cc', 'macro.cc'))
    if ($groups.Count -ne 2 -or $groups[0].Sources.Count -ne 2 -or $groups[1].Prefix.Count -ne 0) {
        throw 'include prefix grouping failed'
    }
    $flags = '/nologo /EHsc /MD /Zi /FS /MP1 /I"' + $root + '" /Fd"' + $root + '/shared.pdb"'
    & $script -Flags $flags -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE) { throw 'automatic PCH compilation failed' }
    if (@(Get-ChildItem obj/md -Filter '*.pch').Count -ne 1) { throw 'PCH not generated' }
    foreach ($name in 'first', 'second') {
        if (-not (Test-Path "obj/md/$name.obj")) { throw "$name object missing" }
        if ((Get-Content "obj/md/$name.d" -Raw -Encoding UTF8) -notmatch 'common\.h') { throw "$name header dependency missing" }
    }
    $pch = Get-ChildItem obj/md -Filter '*.pch' | Select-Object -First 1
    $unchangedTime = $pch.LastWriteTimeUtc
    & $script -Flags $flags -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE -or (Get-Item $pch.FullName).LastWriteTimeUtc -ne $unchangedTime) { throw 'unchanged PCH regenerated' }
    Start-Sleep -Milliseconds 1100
    [IO.File]::AppendAllText("$root/detail.h", "`n", $utf8)
    & $script -Flags $flags -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE -or (Get-Item $pch.FullName).LastWriteTimeUtc -le $unchangedTime) { throw 'indirect header failed to regenerate PCH' }
    $metadataTime = (Get-Item $pch.FullName).LastWriteTimeUtc
    Remove-Item -LiteralPath 'obj/md/first.cc.json'
    Start-Sleep -Milliseconds 1100
    [IO.File]::AppendAllText("$root/detail.h", "`n", $utf8)
    & $script -Flags $flags -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE -or (Get-Item $pch.FullName).LastWriteTimeUtc -le $metadataTime) { throw 'missing dependency metadata allowed stale PCH reuse' }
    $metadataTime = (Get-Item $pch.FullName).LastWriteTimeUtc
    [IO.File]::WriteAllText("$root/obj/md/first.cc.json", '{', $utf8)
    Start-Sleep -Milliseconds 1100
    & $script -Flags $flags -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE -or (Get-Item $pch.FullName).LastWriteTimeUtc -le $metadataTime) { throw 'invalid dependency metadata allowed stale PCH reuse' }
    Remove-Item -LiteralPath $pch.FullName
    $dirtyScript = Join-Path (Split-Path $script) 'find_dirty_srcs.sh'
    $dirty = @(& (Get-Command bash).Source $dirtyScript 'first.cc second.cc' 'obj/md' $root)
    if ($LASTEXITCODE -or $dirty.Count -ne 2) { throw 'missing PCH not detected by incremental build' }
    & $script -Flags $flags -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE -or -not (Test-Path $pch.FullName)) { throw 'missing PCH not regenerated' }
    & $script -Flags $flags -ExtraFlags '/D_IN_TEST_SRC' -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE) { throw 'test variant compilation failed' }
    if (@(Get-ChildItem obj/md -Filter '*.pch').Count -ne 2) { throw 'configuration PCH collision' }
    [IO.File]::WriteAllText("$root/common.h", "#pragma once`nstruct Common { int value[2]; };`n", $utf8)
    & $script -Flags $flags -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE) { throw 'changed header compilation failed' }
    [IO.File]::WriteAllText("$root/main.cc", "int first(); int second(); int main() { return first() == 8 && second() == 8 ? 0 : 1; }`n", $utf8)
    & cl /nologo /EHsc /MD main.cc obj/md/first.obj obj/md/second.obj /Fe:sample.exe /link /DEBUG /PDB:sample.pdb
    if ($LASTEXITCODE) { throw 'PCH objects failed to link' }
    & ./sample.exe
    if ($LASTEXITCODE) { throw 'changed header did not affect executable behavior' }
    & $script -Flags $flags -ObjDir 'obj/md' -Sources 'first.cc' -WorkspaceDir $root
    if ($LASTEXITCODE) { throw 'single creator source compilation failed' }
    & cl /nologo /EHsc /MD main.cc obj/md/first.obj obj/md/second.obj /Fe:sample.exe /link /DEBUG /PDB:sample.pdb
    if ($LASTEXITCODE) { throw 'incremental creator object failed to link with PCH users' }
    & ./sample.exe
    if ($LASTEXITCODE) { throw 'incremental executable behavior changed' }
    foreach ($name in 'cfirst', 'csecond') {
        [IO.File]::WriteAllText("$root/$name.c", "#include <common.h>`nint $name(void) { return sizeof(struct Common); }`n", $utf8)
    }
    & $script -Flags ($flags.Replace('/EHsc', '')) -ObjDir 'obj/c' -Sources 'cfirst.c csecond.c' -WorkspaceDir $root
    if ($LASTEXITCODE -or @(Get-ChildItem obj/c -Filter '*.pch').Count -ne 1) { throw 'C PCH compilation failed' }
    [IO.File]::WriteAllText("$root/distinct.h", "#define CREATOR_ONLY 1`n", $utf8)
    [IO.File]::WriteAllText("$root/comment_first.cc", "// /* literal in a line comment`n#include <distinct.h>`n/* real comment */`n#include <common.h>`nint comment_first() { return CREATOR_ONLY; }`n", $utf8)
    [IO.File]::WriteAllText("$root/comment_second.cc", "#include <common.h>`n#ifdef CREATOR_ONLY`n#error unrelated include prefix leaked`n#endif`nint comment_second() { return 0; }`n", $utf8)
    & $script -Flags $flags -ObjDir 'obj/comments' -Sources 'comment_first.cc comment_second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE) { throw 'comment parsing shared unrelated include prefixes' }
    Write-Output 'PASS: automatic PCH, macro boundary, objects, dependencies, configuration separation, header rebuild, comments'
}
finally {
    [Environment]::CurrentDirectory = $originalDirectory
    Pop-Location
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'temporary path escaped'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
