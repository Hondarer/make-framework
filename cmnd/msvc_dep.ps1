#!/usr/bin/env pwsh
# MSVC の /showIncludes 出力を GNU Make の .d 形式に変換
# Convert MSVC /showIncludes output to GNU Make .d format
#
# 使用方法 (Usage):
#   cl /showIncludes ... 2>&1 | powershell -ExecutionPolicy Bypass -File msvc_dep.ps1 target.obj source.c target.d

$target  = $args[0]
$source  = $args[1]
$depfile = $args[2]

# 引数チェック
if (-not $target -or -not $source -or -not $depfile) {
    Write-Host "Error: Required arguments not provided" -ForegroundColor Red
    Write-Host "Usage: powershell -File msvc_dep.ps1 target.obj source.c target.d"
    exit 1
}

# 依存ファイルのリストを保存 (空ルール生成用)
$deps = @()

# 依存関係ファイルのヘッダーを作成
$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append("${target}: ${source}")

# パイプからの入力を 1 行ずつ処理
foreach ($line in $input) {
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

        # 依存関係を追加 ( ` \<LF>  header` 形式)
        [void]$sb.Append(' \')
        [void]$sb.Append("`n  ${header}")

        # 空ルール生成用に保存
        $deps += $header
    }
    else {
        # ソースファイル名のみの行はスキップ (MSVC がコンパイル開始時に出力するファイル名)
        $sourceName = [System.IO.Path]::GetFileName($source)
        if ($line.Trim() -eq $sourceName) {
            continue
        }

        # MSVC 診断メッセージのファイルパスをフルパスに変換 (VS Code でクリック可能にする)
        $outputLine = $line
        if ($line -match '^(.+?)(\(\d+(?:,\d+)?\)\s*:.*)$') {
            $filePart = $Matches[1]
            $rest     = $Matches[2]
            if (-not [System.IO.Path]::IsPathRooted($filePart)) {
                $fullPath = [System.IO.Path]::GetFullPath($filePart)
                if (Test-Path $fullPath) {
                    $outputLine = "${fullPath}${rest}"
                }
            }
        }

        # 依存関係解析対象でない行を出力 (error/warning は色分け)
        if ($outputLine -match '\berror\b') {
            Write-Host $outputLine -ForegroundColor Red
        }
        elseif ($outputLine -match '\bwarning\b') {
            Write-Host $outputLine -ForegroundColor Yellow
        }
        else {
            Write-Host $outputLine
        }
    }
}

# 末尾に改行を追加
[void]$sb.Append("`n")

# GCC 互換の空ルールを追加 (ヘッダファイルが削除された場合のエラー回避)
foreach ($dep in $deps) {
    [void]$sb.Append("`n${dep}:`n")
}

# .d ファイルを書き出し (BOM なし UTF-8, LF 改行)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($depfile, $sb.ToString(), $utf8NoBom)

# .d ファイルのタイムスタンプを .obj ファイルと同じにする
# (ビルドのたびに .d が更新されることによる無限ループを防ぐ)
if (Test-Path $target) {
    $objTime = (Get-Item $target).LastWriteTime
    (Get-Item $depfile).LastWriteTime = $objTime
}
