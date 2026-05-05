#!/usr/bin/env pwsh
# MSVC ビルド スクリプト共有ユーティリティ
# Shared utility functions for MSVC build scripts

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

function Get-AnsiUtf8Encoding {
    # MSVC ツール (cl.exe/lib.exe/link.exe) の出力は Windows の ANSI コードページ (GetACP()) に従う。
    # .NET Core では Encoding.Default が UTF-8 になるため ANSICodePage から明示取得する。
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
        $ansi = [System.Text.Encoding]::GetEncoding(
            [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        )
    } else {
        # .NET Framework: Encoding.Default が GetACP() ベースのシステム ANSI エンコーディング
        $ansi = [System.Text.Encoding]::Default
    }
    return @{
        Ansi      = $ansi
        Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    }
}

function Resolve-MsvcDiagnosticPath {
    param([string]$Line)

    # MSVC 診断メッセージのファイルパスをフルパスに変換 (VS Code でクリック可能にする)
    if ($Line -match '^(.+?)(\(\d+(?:,\d+)?\)\s*:.*)$') {
        $filePart = $Matches[1]
        $rest     = $Matches[2]
        if (-not [System.IO.Path]::IsPathRooted($filePart)) {
            $fullPath = [System.IO.Path]::GetFullPath($filePart)
            if (Test-Path $fullPath) {
                return "${fullPath}${rest}"
            }
        }
    }
    return $Line
}

function Write-MsvcDiagnosticLine {
    param([string]$Line)

    # エラー/警告を色付きで出力し、診断種別 ('error'|'warning'|'info') を返す
    if ($Line -match '\berror\b') {
        Write-Host $Line -ForegroundColor Red
        return 'error'
    }
    elseif ($Line -match '\bwarning\b') {
        Write-Host $Line -ForegroundColor Yellow
        return 'warning'
    }
    else {
        Write-Host $Line
        return 'info'
    }
}

function Invoke-AnsiToUtf8Passthrough {
    # [Console]::InputEncoding / OutputEncoding は変更しない。
    # stdin をシステムの ANSI コードページで読み、stdout を UTF-8 (BOM なし) として書く。
    $enc = Get-AnsiUtf8Encoding

    $reader = $null
    $writer = $null
    try {
        $reader = [System.IO.StreamReader]::new(
            [Console]::OpenStandardInput(), $enc.Ansi, $false, 4096, $true
        )
        $writer = [System.IO.StreamWriter]::new(
            [Console]::OpenStandardOutput(), $enc.Utf8NoBom, 4096, $true
        )
        $writer.NewLine   = "`n"    # 下流の bash/grep に LF で渡す
        $writer.AutoFlush = $true   # パイプ詰まりを防ぐ

        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            $writer.WriteLine($line)
        }
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $reader) { $reader.Dispose() }
    }
}
