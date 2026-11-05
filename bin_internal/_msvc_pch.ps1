# ソース先頭の無条件 include だけを共有する。define や条件分岐を越えない。
function Get-MsvcIncludePrefix {
    param([string]$Source)
    $inComment = $false
    foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Source).Path)) {
        $line = $line.Trim()
        while ($true) {
            if ($inComment) {
                $end = $line.IndexOf('*/')
                if ($end -lt 0) { $line = ''; break }
                $line = $line.Substring($end + 2).TrimStart()
                $inComment = $false
            }
            elseif ($line.StartsWith('/*')) {
                $inComment = $true
                $line = $line.Substring(2)
            }
            else { break }
        }
        if ($line -eq '') { continue }
        # 行継続はコメントや directive の解釈を変えるため、自動共有を打ち切る。
        if ($line.EndsWith('\')) { break }
        if ($line.StartsWith('//')) { continue }
        if ($line -match '^#\s*include\s*([<"][^>"]+[>"])\s*(?://.*)?$') {
            $Matches[1]
        }
        else { break }
    }
}

function Get-MsvcPchGroups {
    param([string[]]$SourceList)
    $groups = [ordered]@{}
    foreach ($source in $SourceList) {
        $prefix = @(Get-MsvcIncludePrefix $source)
        $path = (Resolve-Path -LiteralPath $source).Path
        $language = if ([IO.Path]::GetExtension($path) -ceq '.c') { 'c' } else { 'cpp' }
        $key = [IO.Path]::GetDirectoryName($path) + '|' + $language
        if ($prefix.Count) { $key += '|' + $prefix[0] } else { $key += '|' + $path }
        if (-not $groups.Contains($key)) {
            $groups[$key] = [pscustomobject]@{ Sources = @(); Prefix = $prefix }
        }
        $group = $groups[$key]
        $group.Sources += $source
        $length = 0
        while ($length -lt $group.Prefix.Count -and $length -lt $prefix.Count -and
               $group.Prefix[$length] -ceq $prefix[$length]) { $length++ }
        $group.Prefix = @($group.Prefix | Select-Object -First $length)
    }
    $groups.Values
}

function Invoke-MsvcPchMake {
    param([string]$Pch, [string]$Source, [hashtable]$CompileParameters, [string]$CompileScript)
    $utf8 = [Text.UTF8Encoding]::new($false)
    $configPath = "$Pch.json"
    $regeneratePath = "$Pch.ps1"
    $makePath = "$Pch.mk"
    $parameters = [ordered]@{}
    foreach ($key in ($CompileParameters.Keys | Sort-Object)) { $parameters[$key] = $CompileParameters[$key] }
    $parameters.DisablePch = $true
    $parameters.Sources = $Source
    $config = [ordered]@{ Script = $CompileScript; Parameters = $parameters } | ConvertTo-Json -Depth 5
    if (-not (Test-Path $configPath) -or [IO.File]::ReadAllText($configPath) -cne $config) {
        [IO.File]::WriteAllText($configPath, $config, $utf8)
    }
    $quotedConfig = $configPath.Replace("'", "''")
    $regenerate = @"
`$ErrorActionPreference = 'Stop'
`$config = Get-Content -LiteralPath '$quotedConfig' -Raw -Encoding UTF8 | ConvertFrom-Json
`$parameters = @{}
foreach (`$property in `$config.Parameters.PSObject.Properties) { `$parameters[`$property.Name] = `$property.Value }
& `$config.Script @parameters
exit `$LASTEXITCODE
"@
    [IO.File]::WriteAllText($regeneratePath, $regenerate, [Text.UTF8Encoding]::new($true))
    $dependency = Join-Path $CompileParameters.ObjDir ([IO.Path]::GetFileName($Source) + '.json')
    $headers = @()
    $metadataMissing = $true
    if (Test-Path -LiteralPath $dependency) {
        try {
            $metadata = Get-Content -LiteralPath $dependency -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $metadata.Data.Includes) {
                $headers = @($metadata.Data.Includes)
                $metadataMissing = $false
            }
        }
        catch { $headers = @() }
    }
    # make のターゲットと前提条件では空白、#、$ を保護する。
    $escapeMake = { param($value) $value.Replace('\', '/').Replace('$', '$$').Replace('#', '\#').Replace(' ', '\ ') }
    $target = & $escapeMake $Pch
    $dependencies = @($Source, $configPath, $CompileScript, $PSCommandPath) + $headers
    $prerequisites = ($dependencies | ForEach-Object { & $escapeMake $_ }) -join ' '
    # recipe は Bash の単一引用符でパスを渡す。
    $shellPath = $regeneratePath.Replace("'", "'\''")
    $makeText = "SHELL := /bin/bash`n.DEFAULT_GOAL := pch`n.PHONY: pch`npch: $target`n${target}: $prerequisites`n`t@powershell -NoProfile -ExecutionPolicy Bypass -File '$shellPath'`n"
    foreach ($header in $headers) { $makeText += "`n$(& $escapeMake $header):`n" }
    [IO.File]::WriteAllText($makePath, $makeText, $utf8)
    $creatorObject = Join-Path $CompileParameters.ObjDir ([IO.Path]::GetFileNameWithoutExtension($Source) + '.obj')
    $makeArguments = @('--no-print-directory', '-f', $makePath, 'pch')
    $pdbMissing = $false
    if ($CompileParameters.Flags -match '/Fd:?(?:"([^"]+)"|(\S+))') {
        $pdb = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        $pdbMissing = -not (Test-Path -LiteralPath $pdb)
    }
    if (-not (Test-Path $creatorObject) -or $pdbMissing -or $metadataMissing) { $makeArguments = @('-B') + $makeArguments }
    & make @makeArguments
    if ($LASTEXITCODE) { throw "PCH make failed: $Pch" }
}
