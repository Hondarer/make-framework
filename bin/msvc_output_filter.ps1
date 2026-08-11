#!/usr/bin/env pwsh
# Windows ネイティブ ツールの出力を UTF-8 に正規化して流す

param(
    [ValidateSet('ConsoleOutput', 'Ansi')]
    [string]$InputEncoding = 'ConsoleOutput'
)

. "$PSScriptRoot/_msvc_utils.ps1"
Invoke-NativeToolPassthroughWithMutex -InputEncoding $InputEncoding
