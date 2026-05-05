#!/usr/bin/env pwsh
# MSVC ビルド スクリプト共有ユーティリティ
# Shared utility functions for MSVC build scripts

$script:MsvcConsoleMutexName = 'Local\c-modernization-kit.makefw.msvc.console'
$script:MsvcConsoleMutexTimeoutMs = 60000
$script:MsvcAnsiReset = [char]27 + '[0m'
$script:MsvcAnsiRed = [char]27 + '[31m'
$script:MsvcAnsiYellow = [char]27 + '[33m'

function Get-WrappedCommandLineLines {
    param(
        [string[]]$Tokens,
        [int]$MaxWidth = 120,
        [string]$Indent = "   ",
        [string]$Continuation = " \"
    )

    if ($Tokens.Count -eq 0) {
        return @()
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

    $wrapped = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $suffix = if ($i -lt ($lines.Count - 1)) { $Continuation } else { "" }
        $wrapped.Add($lines[$i] + $suffix)
    }

    return $wrapped.ToArray()
}

function New-MsvcOutputRecord {
    param(
        [string]$Text,
        [string]$Kind = 'info'
    )

    return [PSCustomObject]@{
        Text = $Text
        Kind = $Kind
    }
}

function Get-MsvcDiagnosticKind {
    param([string]$Line)

    if ($Line -match '\bfatal error\b' -or $Line -match '\berror\b') {
        return 'error'
    }
    if ($Line -match '\bwarning\b') {
        return 'warning'
    }
    return 'info'
}

function ConvertTo-MsvcOutputRecord {
    param([string]$Line)

    $kind = Get-MsvcDiagnosticKind -Line $Line
    return (New-MsvcOutputRecord -Text $Line -Kind $kind)
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

function Write-MsvcOutputRecord {
    param($Record)

    switch ($Record.Kind) {
        'error'   { Write-Host $Record.Text -ForegroundColor Red }
        'warning' { Write-Host $Record.Text -ForegroundColor Yellow }
        default   { Write-Host $Record.Text }
    }
}

function Write-MsvcOutputRecordsUnlocked {
    param([object[]]$Records)

    foreach ($record in $Records) {
        Write-MsvcOutputRecord -Record $record
    }
}

function Write-MsvcOutputRecords {
    param(
        [object[]]$Records,
        [string]$MutexName = $script:MsvcConsoleMutexName,
        [int]$TimeoutMs = $script:MsvcConsoleMutexTimeoutMs
    )

    if ($null -eq $Records -or $Records.Count -eq 0) {
        return
    }

    $mutex = $null
    $lockTaken = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $MutexName)
        try {
            $lockTaken = $mutex.WaitOne($TimeoutMs)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }

        if (-not $lockTaken) {
            Write-Host "Warning: Timed out waiting for MSVC console mutex after $TimeoutMs ms. Falling back to unlocked output." -ForegroundColor Yellow
            Write-MsvcOutputRecordsUnlocked -Records $Records
            return
        }

        Write-MsvcOutputRecordsUnlocked -Records $Records
    }
    finally {
        if ($lockTaken -and $null -ne $mutex) {
            $mutex.ReleaseMutex()
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Get-MsvcAnsiColoredText {
    param($Record)

    switch ($Record.Kind) {
        'error'   { return "$script:MsvcAnsiRed$($Record.Text)$script:MsvcAnsiReset" }
        'warning' { return "$script:MsvcAnsiYellow$($Record.Text)$script:MsvcAnsiReset" }
        default   { return $Record.Text }
    }
}

function Read-AnsiLinesFromStdIn {
    $enc = Get-AnsiUtf8Encoding
    $reader = $null
    $lines = [System.Collections.Generic.List[string]]::new()
    try {
        $reader = [System.IO.StreamReader]::new(
            [Console]::OpenStandardInput(), $enc.Ansi, $false, 4096, $true
        )

        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            $lines.Add($line)
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
    }

    return $lines.ToArray()
}

function Write-MsvcOutputRecordsToStdoutUnlocked {
    param([object[]]$Records)

    $enc = Get-AnsiUtf8Encoding
    $writer = $null
    try {
        $writer = [System.IO.StreamWriter]::new(
            [Console]::OpenStandardOutput(), $enc.Utf8NoBom, 4096, $true
        )
        $writer.NewLine = "`n"
        $writer.AutoFlush = $true

        foreach ($record in $Records) {
            $writer.WriteLine((Get-MsvcAnsiColoredText -Record $record))
        }
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
    }
}

function Write-MsvcOutputRecordsToStdout {
    param(
        [object[]]$Records,
        [string]$MutexName = $script:MsvcConsoleMutexName,
        [int]$TimeoutMs = $script:MsvcConsoleMutexTimeoutMs
    )

    if ($null -eq $Records -or $Records.Count -eq 0) {
        return
    }

    $mutex = $null
    $lockTaken = $false
    try {
        $mutex = [System.Threading.Mutex]::new($false, $MutexName)
        try {
            $lockTaken = $mutex.WaitOne($TimeoutMs)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }

        if (-not $lockTaken) {
            $warningRecord = New-MsvcOutputRecord -Text "Warning: Timed out waiting for MSVC console mutex after $TimeoutMs ms. Falling back to unlocked output." -Kind 'warning'
            Write-MsvcOutputRecordsToStdoutUnlocked -Records @($warningRecord)
            Write-MsvcOutputRecordsToStdoutUnlocked -Records $Records
            return
        }

        Write-MsvcOutputRecordsToStdoutUnlocked -Records $Records
    }
    finally {
        if ($lockTaken -and $null -ne $mutex) {
            $mutex.ReleaseMutex()
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Invoke-MsvcPassthroughWithMutex {
    $records = foreach ($line in Read-AnsiLinesFromStdIn) {
        ConvertTo-MsvcOutputRecord -Line $line
    }
    Write-MsvcOutputRecordsToStdout -Records $records
}
