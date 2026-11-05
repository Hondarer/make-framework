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
$children = @()
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
    [IO.File]::AppendAllText("$root/first.cc", "`n", $utf8)
    & $script -Flags $flags -ObjDir 'obj/md' -Sources 'first.cc' -WorkspaceDir $root
    if ($LASTEXITCODE -or (Get-Item $pch.FullName).LastWriteTimeUtc -ne $unchangedTime) { throw 'source-only edit regenerated PCH' }
    Start-Sleep -Milliseconds 1100
    [IO.File]::AppendAllText("$root/detail.h", "`n", $utf8)
    & $script -Flags $flags -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE -or (Get-Item $pch.FullName).LastWriteTimeUtc -le $unchangedTime) { throw 'indirect header failed to regenerate PCH' }
    $metadataTime = (Get-Item $pch.FullName).LastWriteTimeUtc
    Remove-Item -LiteralPath ($pch.FullName + '.deps.json')
    Start-Sleep -Milliseconds 1100
    [IO.File]::AppendAllText("$root/detail.h", "`n", $utf8)
    & $script -Flags $flags -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE -or (Get-Item $pch.FullName).LastWriteTimeUtc -le $metadataTime) { throw 'missing dependency metadata allowed stale PCH reuse' }
    $metadataTime = (Get-Item $pch.FullName).LastWriteTimeUtc
    [IO.File]::WriteAllText(($pch.FullName + '.deps.json'), '{', $utf8)
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
    & $script -Flags $flags -ObjDir 'obj/md' -Sources 'first.cc' -WorkspaceDir $root -DisablePch
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
    foreach ($sources in @('first.cc second.cc', 'cfirst.c csecond.c')) {
        & $script -Flags ($flags.Replace('/EHsc', '')) -ObjDir 'obj/languages' -Sources $sources -WorkspaceDir $root
        if ($LASTEXITCODE) { throw 'identical flags mixed C and C++ PCH' }
    }
    if (@(Get-ChildItem obj/languages -Filter '*.pch').Count -ne 2) { throw 'C and C++ PCH were not separated' }
    [IO.File]::WriteAllText("$root/distinct.h", "#define CREATOR_ONLY 1`n", $utf8)
    [IO.File]::WriteAllText("$root/comment_first.cc", "// /* literal in a line comment`n#include <distinct.h>`n/* real comment */`n#include <common.h>`nint comment_first() { return CREATOR_ONLY; }`n", $utf8)
    [IO.File]::WriteAllText("$root/comment_second.cc", "#include <common.h>`n#ifdef CREATOR_ONLY`n#error unrelated include prefix leaked`n#endif`nint comment_second() { return 0; }`n", $utf8)
    & $script -Flags $flags -ObjDir 'obj/comments' -Sources 'comment_first.cc comment_second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE) { throw 'comment parsing shared unrelated include prefixes' }
    $relativeFlags = $flags.Replace(('/I"' + $root + '"'), '/I".."')
    $sharedRoot = "$root/shared"
    $sharedTime = $null
    foreach ($part in 'one', 'deeper/two') {
        $directory = "$root/$part"
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Copy-Item first.cc, second.cc -Destination $directory
        Push-Location $directory
        [Environment]::CurrentDirectory = $directory
        try {
            $partFlags = if ($part.Contains('/')) { $relativeFlags.Replace('/I".."', '/I"../.."') } else { $relativeFlags }
            & $script -Flags $partFlags -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root -PchRoot $sharedRoot
            if ($LASTEXITCODE) { throw 'shared directory compilation failed' }
        }
        finally { Pop-Location; [Environment]::CurrentDirectory = $root }
        $sharedPch = @(Get-ChildItem "$sharedRoot/obj/md" -Filter '*.pch')
        if ($sharedPch.Count -ne 1) { throw 'identical directory configurations duplicated PCH' }
        if ($null -ne $sharedTime -and $sharedTime -ne $sharedPch[0].LastWriteTimeUtc) { throw 'second directory regenerated shared PCH' }
        $sharedTime = $sharedPch[0].LastWriteTimeUtc
    }
    foreach ($part in 'three', 'four') {
        $directory = "$root/$part"
        New-Item -ItemType Directory -Path $directory | Out-Null
        Copy-Item first.cc, second.cc -Destination $directory
        $command = "& '$script' -Flags '$relativeFlags' -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir '$root' -PchRoot '$root/concurrent'`nexit `$LASTEXITCODE`n"
        [IO.File]::WriteAllText("$directory/run.ps1", $command, [Text.UTF8Encoding]::new($true))
        $child = Start-Process powershell -WindowStyle Hidden -PassThru -WorkingDirectory $directory `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $directory + '/run.ps1"')) `
            -RedirectStandardOutput "$directory/build.log" -RedirectStandardError "$directory/error.log"
        # 終了後も終了コードを参照できるよう、起動直後にプロセス ハンドルを保持する。
        # see: https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.handle
        $null = $child.Handle
        $children += $child
    }
    foreach ($child in $children) {
        if (-not $child.WaitForExit(120000)) { throw 'concurrent PCH compilation timed out' }
        if ($child.ExitCode -ne 0) {
            Get-Content "$root/three/error.log", "$root/four/error.log", "$root/three/build.log", "$root/four/build.log" -ErrorAction SilentlyContinue | Write-Output
            throw "concurrent PCH compilation failed: $($child.Id) code=$($child.ExitCode)"
        }
    }
    if (@(Get-ChildItem "$root/concurrent/obj/md" -Filter '*.pch').Count -ne 1) { throw 'concurrent creation duplicated PCH' }
    $creations = @(Select-String -Path "$root/three/build.log", "$root/four/build.log" -SimpleMatch '/Yc"common.h"')
    if ($creations.Count -ne 1) { throw 'concurrent callers regenerated shared PCH' }
    $value = 0
    foreach ($part in 'quote_one', 'quote_two') {
        $value++
        $directory = "$root/$part"
        New-Item -ItemType Directory -Path $directory | Out-Null
        [IO.File]::WriteAllText("$directory/local.h", "#define LOCAL_VALUE $value`n", $utf8)
        foreach ($name in 'first', 'second') {
            $source = '#include "local.h"' + "`nstatic_assert(LOCAL_VALUE == $value, `"wrong local header`");`nint $name() { return LOCAL_VALUE; }`n"
            [IO.File]::WriteAllText("$directory/$name.cc", $source, $utf8)
        }
        Push-Location $directory
        [Environment]::CurrentDirectory = $directory
        try {
            & $script -Flags $relativeFlags -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root -PchRoot "$root/quoted"
            if ($LASTEXITCODE) { throw 'quoted local header was shared across directories' }
            foreach ($name in 'first', 'second') {
                [IO.File]::WriteAllText("$directory/$name.cc", "#include <common.h>`nstatic_assert(LOCAL_VALUE == $value, `"wrong forced header`");`nint $name() { return LOCAL_VALUE; }`n", $utf8)
            }
            & $script -Flags ($relativeFlags + ' /FI"local.h"') -ObjDir 'obj/md' -Sources 'first.cc second.cc' -WorkspaceDir $root -PchRoot "$root/forcedcontexts"
            if ($LASTEXITCODE) { throw 'forced local header was shared across directories' }
        }
        finally { Pop-Location; [Environment]::CurrentDirectory = $root }
    }
    if (@(Get-ChildItem "$root/quoted/obj/md" -Filter '*.pch').Count -ne 2) { throw 'quoted header contexts were not separated' }
    if (@(Get-ChildItem "$root/forcedcontexts/obj/md" -Filter '*.pch').Count -ne 2) { throw 'forced header contexts were not separated' }
    [IO.File]::WriteAllText("$root/wrapper.h", "#pragma once`n#include <common.h>`n", $utf8)
    foreach ($name in 'guard_first', 'guard_second') {
        [IO.File]::WriteAllText("$root/$name.c", "#include <wrapper.h>`n#include <common.h>`nint $name(void) { return sizeof(struct Common); }`n", $utf8)
    }
    & $script -Flags ($flags.Replace('/EHsc', '')) -ObjDir 'obj/guards' -Sources 'guard_first.c guard_second.c' -WorkspaceDir $root
    if ($LASTEXITCODE) { throw 'transitively included boundary broke C compilation' }
    $guardMetadata = Get-ChildItem obj/guards -Filter '*.pch.deps.json' | Get-Content -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($guardMetadata.MakefwPchHeader -ne 'wrapper.h') { throw 'redundant boundary did not fall back to the direct header' }
    & $script -Flags ($flags + ' /FI"common.h"') -ObjDir 'obj/forced' -Sources 'first.cc second.cc' -WorkspaceDir $root
    if ($LASTEXITCODE) { throw 'forced include prevented compilation' }
    if (-not (Test-Path obj/forced/first.obj) -or -not (Test-Path obj/forced/second.obj)) { throw 'fallback objects missing' }
    Write-Output 'PASS: automatic PCH, dependencies, incremental linking, comments, shared directories, concurrent creation, guarded includes'
}
finally {
    foreach ($child in $children) {
        if (-not $child.HasExited) { & taskkill.exe /PID $child.Id /T /F | Out-Null; $child.WaitForExit() }
    }
    [Environment]::CurrentDirectory = $originalDirectory
    Pop-Location
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'temporary path escaped'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
