#!/usr/bin/env pwsh
# MSVC ビルド スクリプト共有ユーティリティ
# Shared utility functions for MSVC build scripts

$script:MsvcConsoleMutexName = 'Local\c-modernization-kit.makefw.msvc.console'
$script:MsvcConsoleMutexTimeoutMs = 60000
$script:MsvcAnsiReset = [char]27 + '[0m'
$script:MsvcAnsiRed = [char]27 + '[31m'
$script:MsvcAnsiYellow = [char]27 + '[33m'

if (-not ('Makefw.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;

namespace Makefw
{
    public static class NativeMethods
    {
        [DllImport("kernel32.dll")]
        public static extern uint GetConsoleOutputCP();

        [DllImport("kernel32.dll")]
        public static extern uint GetACP();
    }
}
'@
}

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

function Split-MsvcCommandLineTokens {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return @()
    }

    return @($Line.Trim() -split '\s+' | Where-Object { $_ })
}

function Expand-MsvcResponseFileTokens {
    param([string[]]$Tokens)

    $expandedTokens = [System.Collections.Generic.List[string]]::new()
    foreach ($token in $Tokens) {
        if ($token -notmatch '^@(.+\.rsp)$') {
            $expandedTokens.Add($token)
            continue
        }

        $rspPath = $Matches[1]
        try {
            $resolvedRspPath = [System.IO.Path]::GetFullPath($rspPath)
            if (-not (Test-Path -LiteralPath $resolvedRspPath -PathType Leaf)) {
                $expandedTokens.Add($token)
                continue
            }

            $rspLines = Get-Content -LiteralPath $resolvedRspPath -ErrorAction Stop
            $rspTokens = Split-MsvcCommandLineTokens -Line ($rspLines -join ' ')
            if ($rspTokens.Count -eq 0) {
                $expandedTokens.Add($token)
                continue
            }

            foreach ($rspToken in $rspTokens) {
                $expandedTokens.Add($rspToken)
            }
        }
        catch {
            $expandedTokens.Add($token)
        }
    }

    return $expandedTokens.ToArray()
}

function New-MsvcCommandDisplayRecords {
    param(
        [string[]]$Tokens,
        [switch]$ExpandResponseFiles
    )

    if ($ExpandResponseFiles) {
        $Tokens = Expand-MsvcResponseFileTokens -Tokens $Tokens
    }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($wrappedLine in Get-WrappedCommandLineLines -Tokens $Tokens) {
        $records.Add((New-MsvcOutputRecord -Text $wrappedLine))
    }

    return $records.ToArray()
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
    if ($Line -match '\bwarning\b' -or $Line -match '警告') {
        return 'warning'
    }
    # MSVC リンカ警告コード (LNK4075 など。"warning" 接頭辞を持たず本文だけ流れる場合に対応)
    if ($Line -match '\bLNK\d{4}\b') {
        return 'warning'
    }
    # /LTCG 再開始通知の本文パターン (LNK4075 が "warning" 接頭辞無しで現れるケース)
    if ($Line -match '/LTCG を使用して再開始' -or $Line -match 'restarting link with /LTCG' -or $Line -match 'MSIL \.netmodule') {
        return 'warning'
    }
    return 'info'
}

function ConvertTo-MsvcOutputRecord {
    param([string]$Line)

    $kind = Get-MsvcDiagnosticKind -Line $Line
    return (New-MsvcOutputRecord -Text $Line -Kind $kind)
}

function Get-CodePageEncoding {
    param([uint32]$CodePage)

    if ($PSVersionTable.PSEdition -eq 'Core') {
        [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
    }
    return [System.Text.Encoding]::GetEncoding([int]$CodePage)
}

function Get-WindowsAnsiEncoding {
    $codePage = [Makefw.NativeMethods]::GetACP()
    if ($codePage -eq 0) {
        return [System.Text.Encoding]::Default
    }
    return Get-CodePageEncoding -CodePage $codePage
}

function Get-ConsoleOutputEncoding {
    # cl.exe、link.exe、lib.exe のリダイレクト出力は、現在のコンソール出力コード ページに従う。
    # see: https://learn.microsoft.com/en-us/cpp/build/reference/unicode-support-in-the-compiler-and-linker
    $codePage = [Makefw.NativeMethods]::GetConsoleOutputCP()
    if ($codePage -eq 0) {
        return Get-WindowsAnsiEncoding
    }
    return Get-CodePageEncoding -CodePage $codePage
}

function Get-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
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

    if ([Console]::IsOutputRedirected) {
        Write-MsvcOutputRecordsToUtf8Unlocked -Records $Records
    }
    else {
        foreach ($record in $Records) {
            Write-MsvcOutputRecord -Record $record
        }
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

function Get-NativeToolInputEncoding {
    param(
        [ValidateSet('ConsoleOutput', 'Ansi')]
        [string]$InputEncoding
    )

    if ($InputEncoding -eq 'ConsoleOutput') {
        return Get-ConsoleOutputEncoding
    }
    return Get-WindowsAnsiEncoding
}

function Read-NativeToolLinesFromStdIn {
    param(
        [ValidateSet('ConsoleOutput', 'Ansi')]
        [string]$InputEncoding
    )

    $encoding = Get-NativeToolInputEncoding -InputEncoding $InputEncoding
    $reader = $null
    $lines = [System.Collections.Generic.List[string]]::new()
    try {
        $reader = [System.IO.StreamReader]::new(
            [Console]::OpenStandardInput(), $encoding, $false, 4096, $true
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

function Write-MsvcOutputRecordsToUtf8Unlocked {
    param([object[]]$Records)

    $writer = $null
    try {
        $writer = [System.IO.StreamWriter]::new(
            [Console]::OpenStandardOutput(), (Get-Utf8NoBomEncoding), 4096, $true
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

    Write-MsvcOutputRecords -Records $Records -MutexName $MutexName -TimeoutMs $TimeoutMs
}

function Invoke-NativeToolPassthroughWithMutex {
    param(
        [ValidateSet('ConsoleOutput', 'Ansi')]
        [string]$InputEncoding
    )

    $records = foreach ($line in Read-NativeToolLinesFromStdIn -InputEncoding $InputEncoding) {
        ConvertTo-MsvcOutputRecord -Line $line
    }
    Write-MsvcOutputRecords -Records $records
}

function Invoke-MsvcPassthroughWithMutex {
    Invoke-NativeToolPassthroughWithMutex -InputEncoding ConsoleOutput
}

# cl.exe の fatal error C1060 (compiler is out of heap space) は、並列 make の
# 一時的なメモリ競合でも発生する。同じ待ち時間で一斉に再開すると再発しやすい。
# see: https://learn.microsoft.com/en-us/cpp/error-messages/compiler-errors-1/fatal-error-c1060
$script:MsvcHeapRetryMaxDefault = 3
$script:MsvcHeapRetryBaseMsDefault = 2000
$script:MsvcHeapRetryCapMsDefault = 16000
$script:MsvcHeapRetryFloorMsDefault = 500

function Get-MsvcEnvInt {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Default,
        [Parameter(Mandatory)][int]$Minimum
    )

    $raw = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }

    $parsed = 0
    if (-not [int]::TryParse($raw.Trim(), [ref]$parsed)) {
        throw "ERROR: $Name must be an integer: $raw"
    }
    if ($parsed -lt $Minimum) {
        throw "ERROR: $Name must be >= $Minimum : $raw"
    }
    return $parsed
}

function Get-MsvcHeapRetrySettings {
    $maxRetries = Get-MsvcEnvInt -Name 'MAKEFW_MSVC_HEAP_RETRY_MAX' -Default $script:MsvcHeapRetryMaxDefault -Minimum 0
    $baseMs = Get-MsvcEnvInt -Name 'MAKEFW_MSVC_HEAP_RETRY_BASE_MS' -Default $script:MsvcHeapRetryBaseMsDefault -Minimum 1
    $capMs = Get-MsvcEnvInt -Name 'MAKEFW_MSVC_HEAP_RETRY_CAP_MS' -Default $script:MsvcHeapRetryCapMsDefault -Minimum 1
    if ($capMs -lt $baseMs) {
        $capMs = $baseMs
    }

    return [PSCustomObject]@{
        MaxRetries = $maxRetries
        BaseMs     = $baseMs
        CapMs      = $capMs
        FloorMs    = $script:MsvcHeapRetryFloorMsDefault
    }
}

function Test-MsvcRetryableHeapExhaustion {
    param([string]$Output)

    if ([string]::IsNullOrEmpty($Output)) {
        return $false
    }
    return [bool]($Output -match 'fatal error C1060:')
}

function Get-MsvcHeapRetryDelayMs {
    param(
        [Parameter(Mandatory)][int]$RetryIndex,
        [int]$BaseMs = 2000,
        [int]$CapMs = 16000,
        [int]$FloorMs = 500,
        [scriptblock]$Randomizer = $null
    )

    if ($RetryIndex -lt 1) {
        throw "RetryIndex must be >= 1"
    }

    $exp = [int][Math]::Min($CapMs, $BaseMs * [Math]::Pow(2, $RetryIndex - 1))
    if ($exp -lt 1) {
        $exp = 1
    }

    $floor = $FloorMs
    if ($floor -gt $exp) {
        $floor = $exp
    }
    $exclusiveMax = $exp + 1

    if ($null -eq $Randomizer) {
        return Get-Random -Minimum $floor -Maximum $exclusiveMax
    }
    return [int](& $Randomizer $floor $exclusiveMax)
}

function Get-MsvcHeapRetrySourceLabel {
    param([string[]]$SourceList)

    if ($null -eq $SourceList -or $SourceList.Count -eq 0) {
        return 'cl'
    }

    $first = [System.IO.Path]::GetFileName($SourceList[0])
    if ($SourceList.Count -eq 1) {
        return $first
    }
    $others = $SourceList.Count - 1
    return "$first (+$others more)"
}

function New-MsvcHeapRetryInfoText {
    param(
        [string[]]$SourceList,
        [Parameter(Mandatory)][int]$DelayMs,
        [Parameter(Mandatory)][int]$NextAttempt,
        [Parameter(Mandatory)][int]$MaxAttempts
    )

    # 本文に error / fatal error を含めない。問題マッチャーが成功した再試行を失敗と誤認しないため。
    $label = Get-MsvcHeapRetrySourceLabel -SourceList $SourceList
    $delaySec = ([Math]::Round($DelayMs / 1000.0, 1)).ToString(
        '0.0',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    return "${label}: MSVC C1060 compiler heap exhausted; waiting ${delaySec}s then retrying (${NextAttempt}/${MaxAttempts})"
}

function New-MsvcCompilerRunResult {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$Output = ""
    )

    if ($null -eq $Output) {
        $Output = ""
    }
    return [PSCustomObject]@{
        ExitCode = $ExitCode
        Output   = $Output
    }
}

function Invoke-MsvcCompilerProcess {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string]$Arguments = "",
        [Parameter(Mandatory)][System.Text.Encoding]$OutputEncoding,
        [string]$WorkingDirectory = ""
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $OutputEncoding
    $psi.StandardErrorEncoding = $OutputEncoding
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }

    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return (New-MsvcCompilerRunResult -ExitCode $process.ExitCode -Output ($stdout + $stderr))
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Invoke-MsvcCompilerWithHeapRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$CompileOnce,
        [string[]]$SourceList = @(),
        [int]$MaxRetries = -1,
        [int]$BaseMs = -1,
        [int]$CapMs = -1,
        [scriptblock]$Sleep = $null,
        [scriptblock]$WriteInfo = $null,
        [scriptblock]$Randomizer = $null
    )

    $settings = Get-MsvcHeapRetrySettings
    if ($MaxRetries -ge 0) {
        $settings.MaxRetries = $MaxRetries
    }
    if ($BaseMs -ge 1) {
        $settings.BaseMs = $BaseMs
        if ($settings.CapMs -lt $settings.BaseMs) {
            $settings.CapMs = $settings.BaseMs
        }
    }
    if ($CapMs -ge 1) {
        $settings.CapMs = $CapMs
        if ($settings.CapMs -lt $settings.BaseMs) {
            $settings.CapMs = $settings.BaseMs
        }
    }
    if ($null -eq $Sleep) {
        $Sleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    }
    if ($null -eq $WriteInfo) {
        $WriteInfo = {
            param($Record)
            Write-MsvcOutputRecords -Records @($Record)
        }
    }

    $maxAttempts = 1 + $settings.MaxRetries
    $last = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $last = & $CompileOnce
        if ($null -eq $last) {
            throw "CompileOnce returned null"
        }
        $output = [string]$last.Output
        if ($last.ExitCode -eq 0 -or -not (Test-MsvcRetryableHeapExhaustion -Output $output)) {
            return $last
        }
        if ($attempt -ge $maxAttempts) {
            return $last
        }

        $delayMs = Get-MsvcHeapRetryDelayMs `
            -RetryIndex $attempt `
            -BaseMs $settings.BaseMs `
            -CapMs $settings.CapMs `
            -FloorMs $settings.FloorMs `
            -Randomizer $Randomizer
        $infoText = New-MsvcHeapRetryInfoText `
            -SourceList $SourceList `
            -DelayMs $delayMs `
            -NextAttempt ($attempt + 1) `
            -MaxAttempts $maxAttempts
        & $WriteInfo (New-MsvcOutputRecord -Text $infoText -Kind 'info')
        & $Sleep $delayMs
    }

    return $last
}
