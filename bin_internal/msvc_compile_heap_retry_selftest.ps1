#!/usr/bin/env pwsh
# msvc_compile.ps1 の C1060 内部再試行を、本物の cl.exe なしで確認する。

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/_msvc_utils.ps1"

$script:failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $script:failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
    else {
        Write-Host "PASS: $Message"
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        $script:failures.Add("$Message (expected='$Expected' actual='$Actual')")
        Write-Host "FAIL: $Message (expected='$Expected' actual='$Actual')"
    }
    else {
        Write-Host "PASS: $Message"
    }
}

Write-Host '== detection =='
Assert-True (Test-MsvcRetryableHeapExhaustion -Output "packetTest.cc(150): fatal error C1060: compiler is out of heap space") 'English C1060 is retryable'
Assert-True (Test-MsvcRetryableHeapExhaustion -Output "packetTest.cc(150): fatal error C1060: ヒープの領域を使い果たしました。") 'Japanese C1060 is retryable'
Assert-True (-not (Test-MsvcRetryableHeapExhaustion -Output 'fatal error C2065: undeclared identifier')) 'C2065 is not retryable'
Assert-True (-not (Test-MsvcRetryableHeapExhaustion -Output 'error C1060: not a fatal diagnostic')) 'C1060 without fatal error prefix is not retryable'
Assert-True (-not (Test-MsvcRetryableHeapExhaustion -Output 'fatal error C1076: compiler limit')) 'C1076 is not retryable'
Assert-True (-not (Test-MsvcRetryableHeapExhaustion -Output '')) 'empty output is not retryable'

Write-Host '== delay =='
$captured = $null
$delay = Get-MsvcHeapRetryDelayMs -RetryIndex 1 -BaseMs 2000 -CapMs 16000 -FloorMs 500 -Randomizer {
    param($Minimum, $ExclusiveMax)
    $script:captured = [PSCustomObject]@{ Minimum = $Minimum; ExclusiveMax = $ExclusiveMax }
    return $Minimum
}
Assert-Equal 500 $delay 'injected randomizer can return the floor'
Assert-Equal 500 $captured.Minimum 'retry 1 minimum is 500'
Assert-Equal 2001 $captured.ExclusiveMax 'retry 1 exclusive max is 2001'

$delay2 = Get-MsvcHeapRetryDelayMs -RetryIndex 2 -BaseMs 2000 -CapMs 16000 -FloorMs 500 -Randomizer {
    param($Minimum, $ExclusiveMax)
    $script:captured = [PSCustomObject]@{ Minimum = $Minimum; ExclusiveMax = $ExclusiveMax }
    return $ExclusiveMax - 1
}
Assert-Equal 4000 $delay2 'retry 2 can return the exponential cap'
Assert-Equal 500 $captured.Minimum 'retry 2 minimum is 500'
Assert-Equal 4001 $captured.ExclusiveMax 'retry 2 exclusive max is 4001'

$delay3 = Get-MsvcHeapRetryDelayMs -RetryIndex 3 -BaseMs 2000 -CapMs 16000 -FloorMs 500 -Randomizer {
    param($Minimum, $ExclusiveMax)
    $script:captured = [PSCustomObject]@{ Minimum = $Minimum; ExclusiveMax = $ExclusiveMax }
    return 1234
}
Assert-Equal 1234 $delay3 'retry 3 uses the injected value'
Assert-Equal 8001 $captured.ExclusiveMax 'retry 3 exclusive max is 8001'

$tiny = Get-MsvcHeapRetryDelayMs -RetryIndex 1 -BaseMs 100 -CapMs 200 -FloorMs 500 -Randomizer {
    param($Minimum, $ExclusiveMax)
    $script:captured = [PSCustomObject]@{ Minimum = $Minimum; ExclusiveMax = $ExclusiveMax }
    return $Minimum
}
Assert-Equal 100 $tiny 'floor is clamped down to the exponential cap'
Assert-Equal 100 $captured.Minimum 'clamped minimum equals cap'
Assert-Equal 101 $captured.ExclusiveMax 'clamped exclusive max is cap + 1'

Write-Host '== info text =='
$info = New-MsvcHeapRetryInfoText -SourceList @('src/packetTest.cc') -DelayMs 3400 -NextAttempt 2 -MaxAttempts 4
Assert-Equal 'packetTest.cc: MSVC C1060 compiler heap exhausted; waiting 3.4s then retrying (2/4)' $info 'info text uses the source name and delay'
Assert-True ($info -notmatch 'fatal error') 'info text does not contain fatal error'
Assert-True ($info -notmatch '\berror\b') 'info text does not contain error'

$infoMany = New-MsvcHeapRetryInfoText -SourceList @('a.cc', 'b.cc', 'c.cc') -DelayMs 500 -NextAttempt 3 -MaxAttempts 4
Assert-True ($infoMany.StartsWith('a.cc (+2 more):')) 'batch label includes remaining source count'

Write-Host '== settings =='
$savedMax = [System.Environment]::GetEnvironmentVariable('MAKEFW_MSVC_HEAP_RETRY_MAX')
$savedBase = [System.Environment]::GetEnvironmentVariable('MAKEFW_MSVC_HEAP_RETRY_BASE_MS')
$savedCap = [System.Environment]::GetEnvironmentVariable('MAKEFW_MSVC_HEAP_RETRY_CAP_MS')
try {
    [System.Environment]::SetEnvironmentVariable('MAKEFW_MSVC_HEAP_RETRY_MAX', $null)
    [System.Environment]::SetEnvironmentVariable('MAKEFW_MSVC_HEAP_RETRY_BASE_MS', $null)
    [System.Environment]::SetEnvironmentVariable('MAKEFW_MSVC_HEAP_RETRY_CAP_MS', $null)
    $defaults = Get-MsvcHeapRetrySettings
    Assert-Equal 3 $defaults.MaxRetries 'default max retries is 3'
    Assert-Equal 2000 $defaults.BaseMs 'default base wait is 2000 ms'
    Assert-Equal 16000 $defaults.CapMs 'default cap wait is 16000 ms'

    [System.Environment]::SetEnvironmentVariable('MAKEFW_MSVC_HEAP_RETRY_MAX', '0')
    [System.Environment]::SetEnvironmentVariable('MAKEFW_MSVC_HEAP_RETRY_BASE_MS', '1500')
    [System.Environment]::SetEnvironmentVariable('MAKEFW_MSVC_HEAP_RETRY_CAP_MS', '9000')
    $overridden = Get-MsvcHeapRetrySettings
    Assert-Equal 0 $overridden.MaxRetries 'MAX=0 disables retries'
    Assert-Equal 1500 $overridden.BaseMs 'BASE_MS override is applied'
    Assert-Equal 9000 $overridden.CapMs 'CAP_MS override is applied'
}
finally {
    [System.Environment]::SetEnvironmentVariable('MAKEFW_MSVC_HEAP_RETRY_MAX', $savedMax)
    [System.Environment]::SetEnvironmentVariable('MAKEFW_MSVC_HEAP_RETRY_BASE_MS', $savedBase)
    [System.Environment]::SetEnvironmentVariable('MAKEFW_MSVC_HEAP_RETRY_CAP_MS', $savedCap)
}

function New-FakeC1060Output {
    param([string]$SourceName = 'packetTest.cc')
    return "${SourceName}`r`n${SourceName}(150): fatal error C1060: compiler is out of heap space`r`n"
}

function Invoke-SelftestRetry {
    param(
        [scriptblock]$CompileOnce,
        [int]$MaxRetries = 3,
        [string[]]$SourceList = @('packetTest.cc')
    )

    $script:infos = [System.Collections.Generic.List[object]]::new()
    $script:sleeps = [System.Collections.Generic.List[int]]::new()
    $result = Invoke-MsvcCompilerWithHeapRetry `
        -CompileOnce $CompileOnce `
        -SourceList $SourceList `
        -MaxRetries $MaxRetries `
        -BaseMs 2000 `
        -CapMs 16000 `
        -Randomizer { param($Minimum, $ExclusiveMax) return $Minimum } `
        -Sleep { param([int]$Milliseconds) $script:sleeps.Add($Milliseconds) } `
        -WriteInfo { param($Record) $script:infos.Add($Record) }
    return $result
}

Write-Host '== retry succeeds after 2 C1060 failures =='
$script:calls = 0
$successAfterRetry = Invoke-SelftestRetry -CompileOnce {
    $script:calls++
    if ($script:calls -le 2) {
        return (New-MsvcCompilerRunResult -ExitCode 2 -Output (New-FakeC1060Output))
    }
    return (New-MsvcCompilerRunResult -ExitCode 0 -Output "packetTest.cc`n")
}
Assert-Equal 0 $successAfterRetry.ExitCode 'eventual success returns exit 0'
Assert-Equal 3 $script:calls 'compiler ran 3 times'
Assert-Equal 2 $script:infos.Count 'two info records were written'
Assert-Equal 2 $script:sleeps.Count 'slept twice before success'
Assert-Equal 'info' $script:infos[0].Kind 'retry record is info'
Assert-True ($script:infos[0].Text -notmatch '\berror\b') 'retry record text is not an error line'
Assert-True ($successAfterRetry.Output -notmatch 'fatal error C1060:') 'last output has no C1060'

Write-Host '== retry exhausted stays a failure =='
$script:calls = 0
$exhausted = Invoke-SelftestRetry -CompileOnce {
    $script:calls++
    return (New-MsvcCompilerRunResult -ExitCode 2 -Output (New-FakeC1060Output))
}
Assert-Equal 2 $exhausted.ExitCode 'exhausted retries keep the compiler exit code'
Assert-Equal 4 $script:calls 'compiler ran 4 times (1 initial + 3 retries)'
Assert-Equal 3 $script:infos.Count 'info records only for the 3 waits'
Assert-Equal 3 $script:sleeps.Count 'slept 3 times'
Assert-True ($exhausted.Output -match 'fatal error C1060:') 'last output still has C1060'
Assert-Equal 'info' $script:infos[2].Kind 'final wait record is still info'

Write-Host '== ordinary compile error is not retried =='
$script:calls = 0
$ordinary = Invoke-SelftestRetry -CompileOnce {
    $script:calls++
    return (New-MsvcCompilerRunResult -ExitCode 2 -Output "foo.cc(10): error C2065: undeclared identifier`n")
}
Assert-Equal 2 $ordinary.ExitCode 'ordinary error keeps the compiler exit code'
Assert-Equal 1 $script:calls 'ordinary error compiles once'
Assert-Equal 0 $script:infos.Count 'ordinary error does not write retry info'
Assert-Equal 0 $script:sleeps.Count 'ordinary error does not wait'

Write-Host '== MAX=0 disables retry =='
$script:calls = 0
$disabled = Invoke-SelftestRetry -MaxRetries 0 -CompileOnce {
    $script:calls++
    return (New-MsvcCompilerRunResult -ExitCode 2 -Output (New-FakeC1060Output))
}
Assert-Equal 1 $script:calls 'disabled retry compiles once'
Assert-Equal 0 $script:infos.Count 'disabled retry writes no info'

if ($script:failures.Count -gt 0) {
    Write-Host ""
    Write-Host "$($script:failures.Count) self-test(s) failed."
    exit 1
}

Write-Host ''
Write-Host 'All self-tests passed.'
exit 0
