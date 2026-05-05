#!/usr/bin/env pwsh
# MSVC の /showIncludes 出力を GNU Make の .d 形式に変換
# Convert MSVC /showIncludes output to GNU Make .d format
#
# 使用方法 (Usage):
#   cl /showIncludes ... 2>&1 | powershell -ExecutionPolicy Bypass -File msvc_cl_filter.ps1 target.obj source.c target.d

$target       = $args[0]
$source       = $args[1]
$depfile      = $args[2]
$warnfile     = if ($args.Count -gt 3) { $args[3] } else { $null }
$workspaceDir = if ($args.Count -gt 4) { $args[4].Replace('\', '/') } else { "" }

# 引数チェック
if (-not $target -or -not $source -or -not $depfile) {
    Write-Host "Error: Required arguments not provided" -ForegroundColor Red
    Write-Host "Usage: powershell -File msvc_cl_filter.ps1 target.obj source.c target.d [warn_file]"
    exit 1
}

. "$PSScriptRoot/_msvc_utils.ps1"

# エンコード設定 (MSVC ツールの出力は ANSI コードページ)
$enc          = Get-AnsiUtf8Encoding
$ansiEncoding = $enc.Ansi
$utf8NoBom    = $enc.Utf8NoBom

# 警告行の収集用リスト
# List to collect warning lines
$warnLines = @()
$outputRecords = [System.Collections.Generic.List[object]]::new()

# 依存ファイルのリストを保存 (空ルール生成用)
$deps = @()

# 依存関係ファイルのヘッダーを作成
$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append("${target}: ${source}")

# パイプからの入力を 1 行ずつ処理 (ANSI コードページのバイト列を直接デコード)
$reader = $null
try {
    $reader = [System.IO.StreamReader]::new(
        [Console]::OpenStandardInput(), $ansiEncoding, $false, 4096, $true
    )

    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { break }

        $header = $null

        if ($line -match '^メモ: インクルード ファイル:\s*(.+)$') {
            $header = $Matches[1]
        }
        elseif ($line -match '^Note: including file:\s*(.+)$') {
            $header = $Matches[1]
        }

        if ($null -ne $header) {
            # バックスラッシュをスラッシュに統一
            $header = $header.Replace('\', '/')

            # スペースをエスケープ (Make の依存関係ファイルではスペースは特殊文字)
            $header = $header.Replace(' ', '\ ')

            # workspaceDir が指定されている場合、ワークスペース内のみ追加
            if ($workspaceDir -eq "" -or $header.StartsWith($workspaceDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                # 依存関係を追加 ( ` \<LF>  header` 形式)
                [void]$sb.Append(' \')
                [void]$sb.Append("`n  ${header}")

                # 空ルール生成用に保存
                $deps += $header
            }
        }
        else {
            # ソースファイル名のみの行はスキップ (MSVC がコンパイル開始時に出力するファイル名)
            $sourceName = [System.IO.Path]::GetFileName($source)
            if ($line.Trim() -eq $sourceName) {
                continue
            }

            # MSVC 診断メッセージのファイルパスをフルパスに変換 (VS Code でクリック可能にする)
            $outputLine = Resolve-MsvcDiagnosticPath $line

            # 依存関係解析対象でない行を出力 (error/warning は色分け)
            $record = ConvertTo-MsvcOutputRecord -Line $outputLine
            $outputRecords.Add($record)
            $kind = $record.Kind
            if ($kind -eq 'warning' -and $warnfile) { $warnLines += $outputLine }
        }
    }
} finally {
    if ($null -ne $reader) { $reader.Dispose() }
}

# 末尾に改行を追加
[void]$sb.Append("`n")

# GCC 互換の空ルールを追加 (ヘッダファイルが削除された場合のエラー回避)
foreach ($dep in $deps) {
    [void]$sb.Append("`n${dep}:`n")
}

# .d ファイルを書き出し (BOM なし UTF-8, LF 改行)
[System.IO.File]::WriteAllText($depfile, $sb.ToString(), $utf8NoBom)

# .d ファイルのタイムスタンプを .obj ファイルと同じにする
# (ビルドのたびに .d が更新されることによる無限ループを防ぐ)
if (Test-Path $target) {
    $objTime = (Get-Item $target).LastWriteTime
    (Get-Item $depfile).LastWriteTime = $objTime
}

# 警告行を warn_file に書き出す (警告がなければファイルを作成しない)
# Write warning lines to warn_file (do not create file when no warnings)
if ($warnfile) {
    if ($warnLines.Count -gt 0) {
        [System.IO.File]::WriteAllLines($warnfile, $warnLines, $utf8NoBom)
    } else {
        Remove-Item -Path $warnfile -Force -ErrorAction SilentlyContinue
    }
}

Write-MsvcOutputRecords -Records $outputRecords.ToArray()
