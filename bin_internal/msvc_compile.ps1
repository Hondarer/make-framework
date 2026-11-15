#!/usr/bin/env pwsh
# MSVC 並列コンパイルスクリプト
# 複数ソースファイルを一度に cl.exe に渡し、MSYS プロセス起動オーバーヘッドを削減する
#
# /sourceDependencies <dir> を使用して依存関係を JSON で生成する
# - ロケール非依存 (日本語/英語の正規表現が不要)
# - stdout が軽量化 (インクルード情報が stdout に流れない)
# - /MP との併用が可能 (ディレクトリ引数を使用するため競合しない)
# - Visual Studio 2022 以降が必須
#
# 使用方法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File msvc_compile.ps1 `
#       -Compiler "cl" -Flags "/EHsc /MP /FS" -ObjDir "obj/md" `
#       -Sources "foo.c bar.c baz.c" [-ExtraFlags "-D_IN_TEST_SRC"]

param(
    [string]$Compiler = "cl",
    [string]$Flags = "",
    [string]$ObjDir = "obj",
    [string]$Sources = "",
    [string]$ExtraFlags = "",
    [string]$WorkspaceDir = "",
    [switch]$DryRun,
    [switch]$DisablePch,
    [string]$PchDependencyFile = "",
    [string]$PchRoot = "",
    [switch]$PchCreation
)

. "$PSScriptRoot/_msvc_utils.ps1"
. "$PSScriptRoot/_msvc_pch.ps1"

# cl.exe の出力は現在のコンソール出力コード ページでデコードする。
$consoleOutputEncoding = Get-ConsoleOutputEncoding
$utf8NoBom = Get-Utf8NoBomEncoding

# 単一の実在パス、または空白を含む項目を引用したソース一覧を受け取る。
if ([string]::IsNullOrWhiteSpace($Sources)) {
    exit 0
}
if ($Sources -notmatch '"' -and (Test-Path -LiteralPath $Sources -PathType Leaf)) {
    $sourceList = @($Sources)
}
else {
    $sourceList = @(Split-MsvcCommandLineTokens -Line $Sources | ForEach-Object { $_.Trim('"') })
}

if ($sourceList.Count -eq 0) {
    exit 0
}

# ObjDir が存在しなければ作成
if (-not (Test-Path $ObjDir)) {
    New-Item -ItemType Directory -Path $ObjDir -Force | Out-Null
}

# app/framework、prod/test を区別せず、同じ設定と include 接頭辞の群で PCH を作る。
# 作成元も実際のソースとしてコンパイルし、その .obj を従来どおりリンクする。
# /Yu は指定ヘッダーまでの前処理を置き換えるため、接頭辞が一致する群だけに使う。
# see: https://learn.microsoft.com/en-us/cpp/build/reference/yu-use-precompiled-header-file
if (-not $DisablePch -and -not $DryRun -and $env:MAKEFW_MSVC_PCH -ne '0' -and
    "$Flags $ExtraFlags $env:CL $env:_CL_" -notmatch '(?i)(?:^|\s)[/-](?:Y|Z7)') {
    $groups = @(Get-MsvcPchGroups $sourceList)
    $plainSources = @()
    $canonicalFlags = ConvertTo-MsvcPchFlags $Flags
    $pchFlags = [regex]::Replace($canonicalFlags, '(?i)(?:^|\s)/MP\d*\b', ' ')
    $sharedObjDir = $ObjDir
    if ($PchRoot -ne '') { $sharedObjDir = [IO.Path]::Combine($PchRoot, $ObjDir) }
    $sharedObjDir = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).Path, $sharedObjDir))
    [IO.Directory]::CreateDirectory($sharedObjDir) | Out-Null
    $parallelism = 1
    if ($Flags -match '(?i)/MP(\d+)') { $parallelism = [int]$Matches[1] }
    foreach ($group in $groups) {
        $common = @{ Compiler = $Compiler; Flags = $Flags; ObjDir = $ObjDir
                     ExtraFlags = $ExtraFlags; WorkspaceDir = $WorkspaceDir; DisablePch = $true }
        if ($group.Prefix.Count -eq 0) {
            $plainSources += $group.Sources
            continue
        }
        $context = ''
        if (@($group.Prefix | Where-Object { $_.StartsWith('"') }).Count) {
            $context = Split-Path (Resolve-Path -LiteralPath $group.Sources[0]).Path
        }
        if ("$Flags $ExtraFlags $env:CL $env:_CL_" -match '(?i)(?:^|\s)[/-]FI') {
            $context += '|' + (Split-Path (Resolve-Path -LiteralPath $group.Sources[0]).Path) + '|' + (Get-Location).Path
        }
        $compilerPath = (Get-Command $Compiler -ErrorAction Stop).Source
        $identity = "$compilerPath|$([IO.File]::GetLastWriteTimeUtc($compilerPath).Ticks)|$($group.Language)|$pchFlags|$ExtraFlags|$context|$($group.Prefix -join '|')|$env:CL|$env:_CL_|$env:INCLUDE"
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))).Replace('-', '').Substring(0, 16) }
        finally { $sha.Dispose() }
        $pch = (Join-Path $sharedObjDir "auto_$hash.pch").Replace('\', '/')
        if (Test-Path -LiteralPath "$pch.disabled") { $plainSources += $group.Sources; continue }
        if ($group.Sources.Count -lt (2 * $parallelism) -and -not (Test-Path -LiteralPath $pch)) {
            $plainSources += $group.Sources
            continue
        }
        $header = $group.Prefix[-1].Substring(1, $group.Prefix[-1].Length - 2)
        $common.Flags = $pchFlags
        # 作成元だけを通常コンパイルし直しても、利用側に未解決の PCH 参照を残さない。
        # /Z7 はデバッグ情報を作成元 .obj に置くため、自動 PCH の対象から除く。
        # see: https://learn.microsoft.com/en-us/cpp/build/reference/yl-inject-pch-reference-for-debug-library
        $common.ExtraFlags = "$ExtraFlags /Yl- /Yc`"$header`" /Fp`"$pch`""
        $dependency = ''
        $created = Invoke-MsvcPchMake -Pch $pch -Source $group.Sources[0] -CompileParameters $common -CompileScript $PSCommandPath `
            -Prefix $group.Prefix -DependencyPath ([ref]$dependency)
        if (Test-Path -LiteralPath "$pch.disabled") { $plainSources += $group.Sources; continue }
        $header = (Get-Content -LiteralPath $dependency -Raw -Encoding UTF8 | ConvertFrom-Json).MakefwPchHeader
        $common.Flags = $canonicalFlags
        $common.ExtraFlags = "$ExtraFlags /Yl- /Yu`"$header`" /Fp`"$pch`""
        $remainingSources = @($group.Sources | Where-Object {
            $sourcePath = (Resolve-Path -LiteralPath $_).Path
            $objectPath = [IO.Path]::GetFullPath((Join-Path $ObjDir ([IO.Path]::GetFileNameWithoutExtension($_) + '.obj')))
            -not ($created -and $created.Source -eq $sourcePath -and $created.Object -eq $objectPath -and
                (Test-Path -LiteralPath $objectPath) -and
                (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($objectPath, '.d'))) -and
                (Test-Path -LiteralPath (Join-Path $ObjDir ([IO.Path]::GetFileName($_) + '.json'))))
        })
        if (-not $remainingSources.Count) { continue }
        $remaining = ($remainingSources | ForEach-Object { '"{0}"' -f $_ }) -join ' '
        & $PSCommandPath @common -Sources $remaining -PchDependencyFile $dependency
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    if ($plainSources.Count) {
        & $PSCommandPath -Compiler $Compiler -Flags $Flags -ObjDir $ObjDir -ExtraFlags $ExtraFlags `
            -WorkspaceDir $WorkspaceDir -DisablePch `
            -Sources (($plainSources | ForEach-Object { '"{0}"' -f $_ }) -join ' ')
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    exit 0
}

# 引用符直前のバックスラッシュによるエスケープを避け、末尾の / でディレクトリを指定する。
# see: https://learn.microsoft.com/en-us/cpp/build/reference/fo-object-file-name
$objDirRsp = $ObjDir.Replace('\', '/').TrimEnd('/') + '/'

# レスポンスファイルを作成 (並列ビルド対応で一意のファイル名を使用)
$rspFile = Join-Path $ObjDir "msvc_compile_$([guid]::NewGuid().ToString('N').Substring(0,8)).rsp"

# レスポンスファイルの内容を構築
$rspContent = @()

# 引用されたパスを分割せず、呼び出し元のフラグ文字列をそのまま渡す。
$rspContent += "$Flags $ExtraFlags".Trim()

# コンパイルオプション
$rspContent += "/c"
$rspContent += ('/Fo:"{0}"' -f $objDirRsp)
# /sourceDependencies <dir> でロケール非依存の JSON 依存関係ファイルを生成
# response file では 1 引数として渡さないと cl.exe が引数不足と解釈する
$rspContent += ('/sourceDependencies "{0}"' -f $objDirRsp)

# ソースファイルを追加
$rspContent += @($sourceList | ForEach-Object { '"{0}"' -f $_.Replace('\', '/') })

# レスポンスファイルを書き出し (UTF-8 BOM なし)
[System.IO.File]::WriteAllLines($rspFile, $rspContent, $utf8NoBom)

# 従来の cl コマンド風表示を保ちつつ、CI の 1 行制限に当たらないよう複数行に分割
$outputRecords = [System.Collections.Generic.List[object]]::new()
foreach ($record in (New-MsvcCommandDisplayRecords -Tokens @($Compiler, "@$rspFile") -ExpandResponseFiles)) {
    $outputRecords.Add($record)
}

if ($DryRun) {
    Write-MsvcOutputRecords -Records $outputRecords.ToArray()
    exit 0
}

# 前回の JSON を今回の成功した依存情報と誤認しない。
foreach ($src in $sourceList) {
    Remove-Item -LiteralPath (Join-Path $ObjDir ([IO.Path]::GetFileName($src) + '.json')) -Force -ErrorAction SilentlyContinue
}

# コンパイル実行して出力をキャプチャ
# fatal error C1060: のときは内部で待ち時間をずらして再試行する。
# 最後の試行の出力だけを以降の診断処理へ渡す。
$run = Invoke-MsvcCompilerWithHeapRetry -SourceList $sourceList -CompileOnce {
    Invoke-MsvcCompilerProcess `
        -FileName $Compiler `
        -Arguments ('@"{0}"' -f $rspFile) `
        -OutputEncoding $consoleOutputEncoding `
        -WorkingDirectory (Get-Location).Path
}
$compileExitCode = $run.ExitCode
$output = $run.Output
if ($PchCreation -and $compileExitCode -ne 0 -and $output -match '\berror C285[67]:') {
    # 読み込み済み、または条件分岐内で検出された境界は、手前の直接 include へ戻す。
    Remove-Item -LiteralPath $rspFile -Force -ErrorAction SilentlyContinue
    exit 87
}

# 診断の出力順と翻訳単位の対応は /MP では保証されない。
# 依存情報は警告の候補判定と .d 生成で共有する。
$dependencyIncludes = @{}
$dependenciesComplete = $true
foreach ($src in $sourceList) {
    $jsonPath = Join-Path $ObjDir ([IO.Path]::GetFileName($src) + '.json')
    $rawIncludes = @()
    try {
        $json = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $json.Data -or $null -eq $json.Data.PSObject.Properties['Includes']) {
            throw "Missing Data.Includes"
        }
        $rawIncludes = @($json.Data.Includes)
        if ($PchDependencyFile -ne '') {
            $pchJson = Get-Content -LiteralPath $PchDependencyFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $pchJson.Data -or $null -eq $pchJson.Data.PSObject.Properties['Includes']) {
                throw "Missing PCH Data.Includes"
            }
            $rawIncludes += @($pchJson.Data.Includes)
        }
    }
    catch {
        $dependenciesComplete = $false
        $outputRecords.Add((New-MsvcOutputRecord -Text "Warning: Failed to parse $jsonPath : $_" -Kind 'warning'))
    }
    if ("$Flags $ExtraFlags" -match '/Fp"([^"]+)"') { $rawIncludes += $Matches[1] }
    $dependencyIncludes[$src] = @($rawIncludes | Where-Object { $_ } | Sort-Object -Unique)
}
$diagnostics = [System.Collections.Generic.List[string]]::new()
foreach ($line in $output -split "`r?`n") {
    $trimmedLine = $line.Trim()
    if ($trimmedLine -eq '') { continue }
    $isSourceName = $false
    foreach ($src in $sourceList) {
        if ($trimmedLine -eq $src -or $trimmedLine -eq [IO.Path]::GetFileName($src)) {
            $isSourceName = $true
            break
        }
    }
    if ($isSourceName) { continue }
    $outputLine = Resolve-MsvcDiagnosticPath $trimmedLine
    $record = ConvertTo-MsvcOutputRecord -Line $outputLine
    $outputRecords.Add($record)
    if ($record.Kind -eq 'warning') { $diagnostics.Add($outputLine) }
}
$warnings = Get-MsvcWarningMap -Sources $sourceList -Includes $dependencyIncludes `
    -DependenciesComplete $dependenciesComplete -Diagnostics $diagnostics.ToArray()
Update-MsvcWarningFiles -Sources $sourceList -Warnings $warnings

# ワークスペースの判定は長い形式で行い、.d には呼び出し元の表記で書き出す。
$workspaceCaller = $WorkspaceDir.Replace('\', '/').TrimEnd('/')
$workspaceLong = $workspaceCaller
if ($WorkspaceDir -ne "") {
    $workspaceLong = (Get-MsvcLongPath $WorkspaceDir).Replace('\', '/').TrimEnd('/')
}

# 各ソースファイルの .d ファイルを JSON から生成
# /sourceDependencies <dir> の出力ファイル名: <ソースファイル名>.json
# 例: foo.cc → <ObjDir>\foo.cc.json
foreach ($src in $sourceList) {
    $srcNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $objPath = (Join-Path $ObjDir "$srcNameNoExt.obj").Replace('\', '/')
    $dPath = Join-Path $ObjDir "$srcNameNoExt.d"

    $includes = @()

    foreach ($inc in $dependencyIncludes[$src]) {
        # 配置先との比較は実パスで行い、その後で make 用に空白を保護する。
        $normalized = $inc.Replace('\', '/')
        if ($WorkspaceDir -eq '') {
            $includes += $normalized.Replace(' ', '\ ')
        }
        elseif ($normalized.StartsWith($workspaceLong + '/', [StringComparison]::OrdinalIgnoreCase)) {
            $callerPath = $workspaceCaller + $normalized.Substring($workspaceLong.Length)
            $includes += $callerPath.Replace(' ', '\ ')
        }
        elseif ($normalized.StartsWith($workspaceCaller + '/', [StringComparison]::OrdinalIgnoreCase)) {
            $includes += $normalized.Replace(' ', '\ ')
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    $objMakePath = $objPath.Replace(' ', '\ ')
    $srcMakePath = $src.Replace('\', '/').Replace(' ', '\ ')
    [void]$sb.Append("${objMakePath}: ${srcMakePath}")

    foreach ($inc in $includes) {
        [void]$sb.Append(" \`n  ${inc}")
    }
    [void]$sb.Append("`n")

    # 空ルール (ヘッダー削除時のエラー回避)
    foreach ($inc in $includes) {
        [void]$sb.Append("`n${inc}:`n")
    }

    [System.IO.File]::WriteAllText($dPath, $sb.ToString(), $utf8NoBom)

    # .d のタイムスタンプを .obj と同じにする
    if (Test-Path $objPath) {
        $objTime = (Get-Item $objPath).LastWriteTime
        (Get-Item $dPath).LastWriteTime = $objTime
    }
}

if ($compileExitCode -ne 0) {
    $outputRecords.Add((New-MsvcOutputRecord -Text "Compilation failed with exit code $compileExitCode" -Kind 'error'))
}

# 一時ファイルの削除
Remove-Item -Path $rspFile -Force -ErrorAction SilentlyContinue

Write-MsvcOutputRecords -Records $outputRecords.ToArray()

exit $compileExitCode
