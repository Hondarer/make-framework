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
            $groups[$key] = [pscustomobject]@{ Sources = @(); Prefix = $prefix; Language = $language }
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

function ConvertTo-MsvcPchFlags {
    param([string]$Flags)
    $tokens = @(Split-MsvcCommandLineTokens $Flags)
    $result = @()
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        foreach ($prefix in @('/external:I', '/Fd:', '/Fd', '/I', '-I')) {
            if (-not $token.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
            $path = $token.Substring($prefix.Length).Trim('"')
            if ($path -eq '' -and $i + 1 -lt $tokens.Count) { $i++; $path = $tokens[$i].Trim('"') }
            $absolute = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).Path, $path)).Replace('\', '/')
            if ($absolute.Length -gt [IO.Path]::GetPathRoot($absolute).Length) { $absolute = $absolute.TrimEnd('/') }
            $token = $prefix + '"' + $absolute + '"'
            break
        }
        $result += $token
    }
    $result -join ' '
}

function Invoke-MsvcPchMake {
    param([string]$Pch, [string]$Source, [hashtable]$CompileParameters, [string]$CompileScript,
          [string[]]$Prefix, [ref]$DependencyPath)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Pch.ToLowerInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    # 同じライブラリの複数ディレクトリから、同時に PCH を作成しない。
    # see: https://learn.microsoft.com/en-us/dotnet/api/system.threading.mutex
    $mutex = [Threading.Mutex]::new($false, "Local\makefw.pch.$key")
    $locked = $false
    $abandoned = $false
    try {
        try { $locked = $mutex.WaitOne(600000) }
        catch [Threading.AbandonedMutexException] { $locked = $true; $abandoned = $true }
        if (-not $locked) { throw "PCH creation lock timed out: $Pch" }
        Invoke-MsvcPchMakeCore -Pch $Pch -Source $Source -CompileParameters $CompileParameters `
            -CompileScript $CompileScript -Prefix $Prefix -DependencyPath $DependencyPath -ForceRebuild:$abandoned
    }
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-MsvcPchMakeCore {
    param([string]$Pch, [string]$Source, [hashtable]$CompileParameters, [string]$CompileScript,
          [string[]]$Prefix, [ref]$DependencyPath, [switch]$ForceRebuild)
    if (Test-Path -LiteralPath "$Pch.disabled") { $DependencyPath.Value = "$Pch.deps.json"; return }
    $utf8 = [Text.UTF8Encoding]::new($false)
    $configPath = "$Pch.json"
    $regeneratePath = "$Pch.ps1"
    $makePath = "$Pch.mk"
    $parameters = [ordered]@{}
    foreach ($key in ($CompileParameters.Keys | Sort-Object)) { $parameters[$key] = $CompileParameters[$key] }
    $parameters.DisablePch = $true
    $parameters.Sources = (Resolve-Path -LiteralPath $Source).Path
    $parameters.ObjDir = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).Path, $parameters.ObjDir))
    if (Test-Path -LiteralPath $configPath) {
        try {
            $previous = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $creator = $previous.Parameters.Sources
            if (Test-Path -LiteralPath $creator) {
                $creatorPrefix = @(Get-MsvcIncludePrefix $creator)
                $matchesPrefix = $creatorPrefix.Count -ge $Prefix.Count
                for ($i = 0; $i -lt $Prefix.Count -and $matchesPrefix; $i++) {
                    $matchesPrefix = $creatorPrefix[$i] -ceq $Prefix[$i]
                }
                if ($matchesPrefix) {
                    $parameters.Sources = $creator
                    $parameters.ObjDir = $previous.Parameters.ObjDir
                }
            }
        }
        catch { }
    }
    $config = [ordered]@{ Script = $CompileScript; Prefix = $Prefix; Parameters = $parameters } | ConvertTo-Json -Depth 5
    if (-not (Test-Path $configPath) -or [IO.File]::ReadAllText($configPath) -cne $config) {
        [IO.File]::WriteAllText($configPath, $config, $utf8)
    }
    $quotedConfig = $configPath.Replace("'", "''")
    $quotedPch = $Pch.Replace("'", "''")
    $regenerate = @"
`$ErrorActionPreference = 'Stop'
`$config = Get-Content -LiteralPath '$quotedConfig' -Raw -Encoding UTF8 | ConvertFrom-Json
`$parameters = @{}
foreach (`$property in `$config.Parameters.PSObject.Properties) { `$parameters[`$property.Name] = `$property.Value }
`$successful = `$false
try {
    `$originalExtra = `$parameters.ExtraFlags
    `$parameters.PchCreation = `$true
    `$code = 87
    for (`$index = `$config.Prefix.Count - 1; `$index -ge 0; `$index--) {
        `$boundary = `$config.Prefix[`$index].Substring(1, `$config.Prefix[`$index].Length - 2)
        `$parameters.ExtraFlags = [regex]::Replace(`$originalExtra, '/Yc"[^"]+"', ('/Yc"' + `$boundary + '"'))
        & `$config.Script @parameters
        `$code = `$LASTEXITCODE
        if (`$code -ne 87) { break }
    }
    if (`$code -eq 0) {
        `$dependency = Join-Path `$parameters.ObjDir ([IO.Path]::GetFileName(`$parameters.Sources) + '.json')
        `$metadata = Get-Content -LiteralPath `$dependency -Raw -Encoding UTF8 | ConvertFrom-Json
        `$metadata | Add-Member -NotePropertyName MakefwPchHeader -NotePropertyValue `$boundary -Force
        [IO.File]::WriteAllText('$quotedPch.deps.json', (`$metadata | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new(`$false))
        `$successful = `$true
        if (`$env:MAKEFW_PCH_RESULT) {
            `$receipt = @{ Source = `$parameters.Sources; Object = (Join-Path `$parameters.ObjDir ([IO.Path]::GetFileNameWithoutExtension(`$parameters.Sources) + '.obj')) }
            [IO.File]::WriteAllText(`$env:MAKEFW_PCH_RESULT, (`$receipt | ConvertTo-Json), [Text.UTF8Encoding]::new(`$false))
        }
    }
    elseif (`$code -eq 87) {
        [IO.File]::WriteAllText('$quotedPch.disabled', 'No usable direct include boundary', [Text.UTF8Encoding]::new(`$false))
        `$code = 0
    }
}
finally {
    if (-not `$successful) { Remove-Item -LiteralPath '$quotedPch' -Force -ErrorAction SilentlyContinue }
}
exit `$code
"@
    [IO.File]::WriteAllText($regeneratePath, $regenerate, [Text.UTF8Encoding]::new($true))
    $dependency = "$Pch.deps.json"
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
    $dependencies = @($configPath, $CompileScript, $PSCommandPath) + $headers
    $prerequisites = ($dependencies | ForEach-Object { & $escapeMake $_ }) -join ' '
    # recipe は Bash の単一引用符でパスを渡す。
    $shellPath = $regeneratePath.Replace("'", "'\''")
    $makeText = "SHELL := /bin/bash`n.DEFAULT_GOAL := pch`n.PHONY: pch`npch: $target`n${target}: $prerequisites`n`t@powershell -NoProfile -ExecutionPolicy Bypass -File '$shellPath'`n"
    foreach ($header in $headers) { $makeText += "`n$(& $escapeMake $header):`n" }
    [IO.File]::WriteAllText($makePath, $makeText, $utf8)
    $creatorObject = Join-Path $parameters.ObjDir ([IO.Path]::GetFileNameWithoutExtension($parameters.Sources) + '.obj')
    $makeArguments = @('--no-print-directory', '-f', $makePath, 'pch')
    $pdbMissing = $false
    if ($CompileParameters.Flags -match '/Fd:?(?:"([^"]+)"|(\S+))') {
        $pdb = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        $pdbMissing = -not (Test-Path -LiteralPath $pdb)
    }
    if (-not (Test-Path $creatorObject) -or $pdbMissing -or $metadataMissing -or $ForceRebuild) { $makeArguments = @('-B') + $makeArguments }
    # 今回 make が実行した生成 recipe だけを通知する。日時や既存 .obj からは推測しない。
    $receiptPath = Join-Path ([IO.Path]::GetTempPath()) ('makefw-pch-' + [guid]::NewGuid().ToString('N') + '.json')
    $previousResult = $env:MAKEFW_PCH_RESULT
    try {
        $env:MAKEFW_PCH_RESULT = $receiptPath
        # 関数の戻り値へコンパイラの標準出力を混入させない。
        & make @makeArguments | Out-Host
        if ($LASTEXITCODE) { throw "PCH make failed: $Pch" }
        if (Test-Path -LiteralPath $receiptPath) {
            Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
    }
    finally {
        $env:MAKEFW_PCH_RESULT = $previousResult
        Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
    }
    $DependencyPath.Value = $dependency
}
