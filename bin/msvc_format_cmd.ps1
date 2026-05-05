#!/usr/bin/env pwsh
# MSVC コマンドライン表示用フォーマッタ
# stdin から1行を読み込み、120 文字幅で折り返して表示する
# Format MSVC command line: reads one line from stdin and prints with line-wrapping
#
# 使用方法 (Usage):
#   echo "cl /W4 /c foo.c bar.c ..." | powershell -ExecutionPolicy Bypass -File msvc_format_cmd.ps1

. "$PSScriptRoot/_msvc_utils.ps1"

$line = $null
try {
    $line = [Console]::In.ReadLine()
}
catch { }

if (-not [string]::IsNullOrWhiteSpace($line)) {
    $tokens = $line.Trim() -split '\s+' | Where-Object { $_ }
    Write-WrappedCommandLine -Tokens $tokens
}
