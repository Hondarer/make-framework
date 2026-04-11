#!/usr/bin/env pwsh
# MSVC link.exe の出力を UTF-8 に正規化してそのまま流す
# Normalize MSVC link.exe output to UTF-8 and pass it through unchanged

$cp932     = [System.Text.Encoding]::GetEncoding(932)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Get-JapaneseScore([string]$text) {
    if ([string]::IsNullOrEmpty($text)) {
        return 0
    }

    $score = 0
    foreach ($ch in $text.ToCharArray()) {
        $code = [int][char]$ch
        if (($code -ge 0x3040 -and $code -le 0x30FF) -or ($code -ge 0x4E00 -and $code -le 0x9FFF)) {
            $score++
        }
    }

    return $score
}

function Repair-Utf8AsCp932Mojibake([string]$line) {
    if ([string]::IsNullOrEmpty($line)) {
        return $line
    }

    try {
        $repaired = [System.Text.Encoding]::UTF8.GetString($cp932.GetBytes($line))
        if ((Get-JapaneseScore $repaired) -gt (Get-JapaneseScore $line)) {
            return $repaired
        }
    }
    catch {
    }

    return $line
}

foreach ($line in $input) {
    Write-Output (Repair-Utf8AsCp932Mojibake $line)
}
