#!/usr/bin/env pwsh
# MSVC バッチコンパイルスクリプト
# 複数ソースファイルを一度に cl.exe に渡し、MSYS プロセス起動オーバーヘッドを削減する
#
# /showIncludes を使用して依存関係を抽出し、各ソースファイルの .d を生成
#
# 使用方法:
#   powershell -ExecutionPolicy Bypass -File msvc_batch_compile.ps1 `
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

# レスポンスファイルを作成 (並列ビルド対応で一意のファイル名を使用)
$rspFile = Join-Path $ObjDir "batch_compile_$([guid]::NewGuid().ToString('N').Substring(0,8)).rsp"

# レスポンスファイルの内容を構築
$rspContent = @()

# フラグを追加 (スペースで分割)
$allFlags = "$Flags $ExtraFlags".Trim() -split '\s+' | Where-Object { $_ }
$rspContent += $allFlags

# コンパイルオプション
$objDirWin = $ObjDir.Replace('/', '\')
$rspContent += "/c"
$rspContent += "/Fo:$objDirWin\"
$rspContent += "/showIncludes"

# ソースファイルを追加
$rspContent += $sourceList

# レスポンスファイルを書き出し (UTF-8 BOM なし)
[System.IO.File]::WriteAllLines($rspFile, $rspContent, $utf8NoBom)

# 従来の cl コマンド風に表示 (フルフラグ)
$displayFlags = ($allFlags -join ' ')
$displaySrcs = ($sourceList -join ' ')
Write-Host "$Compiler $displayFlags /c /Fo:$objDirWin\ $displaySrcs"

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

# ソースファイルごとに依存関係を抽出
# cl.exe は各ソースファイルの処理開始時にファイル名を出力する
$currentSource = $null
$deps = @{}  # source -> includes のハッシュテーブル

foreach ($line in $output -split "`r?`n") {
    # ソースファイル名の行を検出 (拡張子のみの行)
    $trimmedLine = $line.Trim()
    foreach ($src in $sourceList) {
        if ($trimmedLine -eq $src -or $trimmedLine -eq [System.IO.Path]::GetFileName($src)) {
            $currentSource = $src
            if (-not $deps.ContainsKey($currentSource)) {
                $deps[$currentSource] = @()
            }
            break
        }
    }

    # /showIncludes 出力を抽出
    $header = $null
    if ($line -match '^メモ: インクルード ファイル:\s*(.+)$') {
        $header = $Matches[1]
    }
    elseif ($line -match '^Note: including file:\s*(.+)$') {
        $header = $Matches[1]
    }

    if ($null -ne $header -and $null -ne $currentSource) {
        # バックスラッシュをスラッシュに変換、スペースをエスケープ
        $header = $header.Replace('\', '/').Replace(' ', '\ ')
        # WorkspaceDir が指定されている場合、ワークスペース内のみ追加
        if ($WorkspaceDir -eq "" -or $header.StartsWith($WorkspaceDir.Replace('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
            $deps[$currentSource] += $header
        }
    }
    elseif ($null -eq $header -and $trimmedLine -ne "" -and $null -ne $currentSource) {
        # ソースファイル名以外の通常出力 (エラー、警告など)
        $isSourceName = $false
        foreach ($src in $sourceList) {
            if ($trimmedLine -eq $src -or $trimmedLine -eq [System.IO.Path]::GetFileName($src)) {
                $isSourceName = $true
                break
            }
        }
        if (-not $isSourceName) {
            # エラー/警告を色付きで出力
            if ($trimmedLine -match '\berror\b') {
                Write-Host $trimmedLine -ForegroundColor Red
            }
            elseif ($trimmedLine -match '\bwarning\b') {
                Write-Host $trimmedLine -ForegroundColor Yellow
            }
            else {
                Write-Host $trimmedLine
            }
        }
    }
}

# 各ソースファイルの .d ファイルを生成
foreach ($src in $sourceList) {
    $srcName = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $objPath = (Join-Path $ObjDir "$srcName.obj").Replace('\', '/')
    $dPath = Join-Path $ObjDir "$srcName.d"

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("${objPath}: ${src}")

    if ($deps.ContainsKey($src)) {
        foreach ($inc in $deps[$src]) {
            [void]$sb.Append(" \`n  ${inc}")
        }
    }
    [void]$sb.Append("`n")

    # 空ルール (ヘッダー削除時のエラー回避)
    if ($deps.ContainsKey($src)) {
        foreach ($inc in $deps[$src]) {
            [void]$sb.Append("`n${inc}:`n")
        }
    }

    [System.IO.File]::WriteAllText($dPath, $sb.ToString(), $utf8NoBom)

    # .d のタイムスタンプを .obj と同じにする
    if (Test-Path $objPath) {
        $objTime = (Get-Item $objPath).LastWriteTime
        (Get-Item $dPath).LastWriteTime = $objTime
    }
}

if ($compileExitCode -ne 0) {
    Write-Host "Compilation failed with exit code $compileExitCode" -ForegroundColor Red
}

# 一時ファイルの削除
Remove-Item -Path $rspFile -Force -ErrorAction SilentlyContinue

exit $compileExitCode
