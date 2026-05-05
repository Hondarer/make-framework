#!/usr/bin/env pwsh
# MSVC link.exe の出力を UTF-8 に正規化してそのまま流す
# Normalize MSVC link.exe output to UTF-8 and pass it through unchanged

. "$PSScriptRoot/_msvc_utils.ps1"
Invoke-AnsiToUtf8Passthrough
