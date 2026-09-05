#!/usr/bin/env pwsh
# _msvc_utils.ps1 の MSVC コンソール Mutex 名の決定を確認する。

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

$savedMakefwHome = [System.Environment]::GetEnvironmentVariable('MAKEFW_HOME')
try {
    Write-Host '== MAKEFW_HOME is not set =='
    [System.Environment]::SetEnvironmentVariable('MAKEFW_HOME', $null)
    $bare = Get-MsvcConsoleMutexName
    Assert-Equal 'Local\makefw.msvc.console' $bare 'unset MAKEFW_HOME uses the base name'

    Write-Host '== MAKEFW_HOME is set =='
    [System.Environment]::SetEnvironmentVariable('MAKEFW_HOME', 'C:\repos\my-workspace\framework\makefw')
    $named = Get-MsvcConsoleMutexName
    Assert-True ($named.StartsWith('Local\makefw.msvc.console.')) 'set MAKEFW_HOME keeps the base name as prefix'
    Assert-True ($named -match '^Local\\makefw\.msvc\.console\.[0-9a-f]{16}$') 'suffix is a 16 character hex digest'
    Assert-Equal 1 ([regex]::Matches($named, '\\').Count) 'only the namespace prefix contains a backslash'
    Assert-True ($named.Length -lt 260) 'mutex name is shorter than the 260 character limit'

    Write-Host '== path separators and casing are normalized =='
    [System.Environment]::SetEnvironmentVariable('MAKEFW_HOME', 'c:/repos/my-workspace/framework/makefw/')
    Assert-Equal $named (Get-MsvcConsoleMutexName) 'separator, casing and trailing slash do not change the name'

    Write-Host '== different workspaces get different names =='
    [System.Environment]::SetEnvironmentVariable('MAKEFW_HOME', 'C:\repos\other-workspace\framework\makefw')
    Assert-True ($named -ne (Get-MsvcConsoleMutexName)) 'another MAKEFW_HOME yields another name'

    Write-Host '== the loaded default follows the same rule =='
    Assert-True ($script:MsvcConsoleMutexName.StartsWith('Local\makefw.msvc.console')) 'the dot-sourced default uses the base name'
}
finally {
    [System.Environment]::SetEnvironmentVariable('MAKEFW_HOME', $savedMakefwHome)
}

if ($script:failures.Count -gt 0) {
    Write-Host ""
    Write-Host "$($script:failures.Count) self-test(s) failed."
    exit 1
}

Write-Host ''
Write-Host 'All self-tests passed.'
exit 0
