#!/usr/bin/env pwsh
# MSVC グループコンパイルスクリプト
# 複数ソースファイルを一度に cl.exe に渡し、MSYS プロセス起動オーバーヘッドを削減する
#
# /sourceDependencies <dir> を使用して依存関係を JSON で生成する
# - ロケール非依存 (日本語/英語の正規表現が不要)
# - stdout が軽量化 (インクルード情報が stdout に流れない)
# - /MP との併用が可能 (ディレクトリ引数を使用するため競合しない)
# - VS 2019 16.7+ 必須
#
# 使用方法:
#   powershell -ExecutionPolicy Bypass -File msvc_group_compile.ps1 `
#       -Compiler "cl" -Flags "/EHsc /MP /FS" -ObjDir "obj/md" `
#       -Sources "foo.c bar.c baz.c" [-ExtraFlags "-D_IN_TEST_SRC"]

param(
    [string]$Compiler = "cl",
    [string]$Flags = "",
    [string]$ObjDir = "obj",
    [string]$Sources = "",
    [string]$ExtraFlags = "",
    [string]$WorkspaceDir = "",
    [switch]$DryRun
)

function Write-WrappedCommandLine {
    param(
        [string[]]$Tokens,
        [int]$MaxWidth = 120,
        [string]$Indent = "   ",
        [string]$Continuation = " \"
    )

    if ($Tokens.Count -eq 0) {
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $currentLine = ""

    foreach ($token in $Tokens) {
        if ([string]::IsNullOrEmpty($currentLine)) {
            $currentLine = $token
            continue
        }

        $candidate = "$currentLine $token"
        if ($candidate.Length -le $MaxWidth) {
            $currentLine = $candidate
            continue
        }

        $lines.Add($currentLine)
        $currentLine = "${Indent}${token}"
    }

    if (-not [string]::IsNullOrEmpty($currentLine)) {
        $lines.Add($currentLine)
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $suffix = if ($i -lt ($lines.Count - 1)) { $Continuation } else { "" }
        Write-Host ($lines[$i] + $suffix)
    }
}

# エンコード設定 (cl.exe 出力は ANSI コードページ)
if ($PSVersionTable.PSEdition -eq 'Core') {
    [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
    $ansiEncoding = [System.Text.Encoding]::GetEncoding(
        [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    )
} else {
    $ansiEncoding = [System.Text.Encoding]::Default
}
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# ソースファイルリストをパース
$sourceList = $Sources -split '\s+' | Where-Object { $_ }

if ($sourceList.Count -eq 0) {
    exit 0
}

# ObjDir が存在しなければ作成
if (-not (Test-Path $ObjDir)) {
    New-Item -ItemType Directory -Path $ObjDir -Force | Out-Null
}

# Windows パス形式に変換
$objDirWin = $ObjDir.Replace('/', '\')

# レスポンスファイルを作成 (並列ビルド対応で一意のファイル名を使用)
$rspFile = Join-Path $ObjDir "group_compile_$([guid]::NewGuid().ToString('N').Substring(0,8)).rsp"

# レスポンスファイルの内容を構築
$rspContent = @()

# フラグを追加 (スペースで分割)
$allFlags = "$Flags $ExtraFlags".Trim() -split '\s+' | Where-Object { $_ }
$rspContent += $allFlags

# コンパイルオプション
$rspContent += "/c"
$rspContent += "/Fo:$objDirWin\"
# /sourceDependencies <dir> でロケール非依存の JSON 依存関係ファイルを生成
# /MP と組み合わせるためディレクトリ引数を使用 (trailing backslash でディレクトリと明示)
$rspContent += "/sourceDependencies $objDirWin\"

# ソースファイルを追加
$rspContent += $sourceList

# レスポンスファイルを書き出し (UTF-8 BOM なし)
[System.IO.File]::WriteAllLines($rspFile, $rspContent, $utf8NoBom)

# 従来の cl コマンド風表示を保ちつつ、CI の 1 行制限に当たらないよう複数行に分割
$displayTokens = @($Compiler) + $allFlags + @("/c", "/Fo:$objDirWin\", "/sourceDependencies $objDirWin\") + $sourceList
Write-WrappedCommandLine -Tokens $displayTokens

if ($DryRun) {
    exit 0
}

# コンパイル実行して出力をキャプチャ
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $Compiler
$psi.Arguments = "@$rspFile"
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = $ansiEncoding
$psi.StandardErrorEncoding = $ansiEncoding
$psi.WorkingDirectory = (Get-Location).Path

$process = [System.Diagnostics.Process]::Start($psi)

# 出力を読み取り
$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
$process.WaitForExit()
$compileExitCode = $process.ExitCode

# 全出力を結合 (cl.exe は stdout と stderr の両方に出力する可能性がある)
$output = $stdout + $stderr

# ソースファイルごとに警告を収集
# /sourceDependencies 使用時は "Note: including file:" 行が出ないため、
# ソース名と警告/エラー行のみを抽出する
$currentSource = $null
$warnings = @{}  # source -> warning lines のハッシュテーブル

foreach ($line in $output -split "`r?`n") {
    $trimmedLine = $line.Trim()

    # ソースファイル名の行を検出 (拡張子のみの行)
    foreach ($src in $sourceList) {
        if ($trimmedLine -eq $src -or $trimmedLine -eq [System.IO.Path]::GetFileName($src)) {
            $currentSource = $src
            break
        }
    }

    # 警告/エラー行を出力 (インクルード行は出ないため全行が診断対象)
    # $currentSource が null の段階 (ソースファイル名行より前) のエラーも出力する
    if ($trimmedLine -ne "") {
        $isSourceName = $false
        foreach ($src in $sourceList) {
            if ($trimmedLine -eq $src -or $trimmedLine -eq [System.IO.Path]::GetFileName($src)) {
                $isSourceName = $true
                break
            }
        }
        if (-not $isSourceName) {
            # MSVC 診断メッセージのファイルパスをフルパスに変換 (VS Code でクリック可能にする)
            $outputLine = $trimmedLine
            if ($trimmedLine -match '^(.+?)(\(\d+(?:,\d+)?\)\s*:.*)$') {
                $filePart = $Matches[1]
                $rest = $Matches[2]
                if (-not [System.IO.Path]::IsPathRooted($filePart)) {
                    $fullPath = [System.IO.Path]::GetFullPath($filePart)
                    if (Test-Path $fullPath) {
                        $outputLine = "${fullPath}${rest}"
                    }
                }
            }

            # エラー/警告を色付きで出力
            if ($outputLine -match '\berror\b') {
                Write-Host $outputLine -ForegroundColor Red
            }
            elseif ($outputLine -match '\bwarning\b') {
                Write-Host $outputLine -ForegroundColor Yellow
                if ($null -ne $currentSource) {
                    if (-not $warnings.ContainsKey($currentSource)) {
                        $warnings[$currentSource] = @()
                    }
                    $warnings[$currentSource] += $outputLine
                }
            }
            else {
                Write-Host $outputLine
            }
        }
    }
}

# 各ソースファイルの .d ファイルを JSON から生成
# /sourceDependencies <dir> の出力ファイル名: <ソースファイル名>.json
# 例: foo.cc → <ObjDir>\foo.cc.json
foreach ($src in $sourceList) {
    $srcBaseName = [System.IO.Path]::GetFileName($src)
    $srcNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $objPath = (Join-Path $ObjDir "$srcNameNoExt.obj").Replace('\', '/')
    $dPath = Join-Path $ObjDir "$srcNameNoExt.d"
    $jsonPath = Join-Path $ObjDir "$srcBaseName.json"

    $includes = @()

    if (Test-Path $jsonPath) {
        try {
            $json = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $rawIncludes = $json.Data.Includes
            foreach ($inc in $rawIncludes) {
                # バックスラッシュをスラッシュに変換、スペースをエスケープ
                $normalized = $inc.Replace('\', '/').Replace(' ', '\ ')
                # WorkspaceDir が指定されている場合、ワークスペース内のみ追加
                if ($WorkspaceDir -eq "" -or $normalized.StartsWith($WorkspaceDir.Replace('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
                    $includes += $normalized
                }
            }
        }
        catch {
            Write-Host "Warning: Failed to parse $jsonPath : $_" -ForegroundColor Yellow
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("${objPath}: ${src}")

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

    # .warn ファイルを生成 (警告がなければ削除)
    $warnPath = "$src.warn"
    if ($warnings.ContainsKey($src) -and $warnings[$src].Count -gt 0) {
        [System.IO.File]::WriteAllLines($warnPath, $warnings[$src], $utf8NoBom)
    } else {
        Remove-Item -Path $warnPath -Force -ErrorAction SilentlyContinue
    }
}

if ($compileExitCode -ne 0) {
    Write-Host "Compilation failed with exit code $compileExitCode" -ForegroundColor Red
}

# 一時ファイルの削除
Remove-Item -Path $rspFile -Force -ErrorAction SilentlyContinue

exit $compileExitCode
