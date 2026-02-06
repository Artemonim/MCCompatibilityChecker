# * Shared hash cache helpers for MCCC.json.

function Get-McccHashCacheDefault {
  [OutputType([hashtable])]
  param()

  return @{
    schemaVersion = 1
    updatedUtc = ""
    passed = @{}
  }
}

function Get-McccHashCachePath {
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [string]$GameModsDir,
    [Parameter(Mandatory = $false)]
    [string]$FileName = "MCCC.json"
  )

  if ([string]::IsNullOrWhiteSpace($GameModsDir)) { return "" }
  if ([string]::IsNullOrWhiteSpace($FileName)) { $FileName = "MCCC.json" }
  return (Join-Path -Path $GameModsDir -ChildPath $FileName)
}

function Read-McccHashCache {
  <#
  .SYNOPSIS
  Reads MCCC.json and returns a normalized hashtable.

  .DESCRIPTION
  This function never throws for missing/invalid files. It returns an empty cache instead.
  #>
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $cache = Get-McccHashCacheDefault
  if ([string]::IsNullOrWhiteSpace($Path)) { return $cache }
  if (-not (Test-Path -LiteralPath $Path)) { return $cache }

  try {
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return $cache }
    $parsed = ConvertFrom-Json -InputObject $raw -AsHashtable -ErrorAction Stop
    if ($null -eq $parsed) { return $cache }

    if ($parsed.ContainsKey("schemaVersion")) {
      $cache["schemaVersion"] = [int]$parsed["schemaVersion"]
    }
    if ($parsed.ContainsKey("updatedUtc")) {
      $cache["updatedUtc"] = [string]$parsed["updatedUtc"]
    }

    if ($parsed.ContainsKey("passed") -and $parsed["passed"] -is [hashtable]) {
      $cache["passed"] = $parsed["passed"]
    } else {
      $cache["passed"] = @{}
    }
  } catch {
    Write-Verbose ("Failed to read MCCC hash cache '{0}': {1}" -f $Path, $_.Exception.Message)
  }

  return $cache
}

function Write-McccHashCache {
  <#
  .SYNOPSIS
  Writes the cache to disk as JSON.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [hashtable]$Cache
  )

  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if ($null -eq $Cache) { return }

  $Cache["updatedUtc"] = (Get-Date).ToUniversalTime().ToString("o")
  if (-not $Cache.ContainsKey("schemaVersion")) { $Cache["schemaVersion"] = 1 }
  if (-not $Cache.ContainsKey("passed") -or -not ($Cache["passed"] -is [hashtable])) { $Cache["passed"] = @{} }

  $parent = Split-Path -Path $Path -Parent
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
  }

  $json = ConvertTo-Json -InputObject $Cache -Depth 6
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8 -ErrorAction Stop
}

function Get-Sha256LowerHex {
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $false)]
    [int]$Retries = 3,
    [Parameter(Mandatory = $false)]
    [int]$DelayMs = 200
  )

  if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
  if (-not (Test-Path -LiteralPath $Path)) { return "" }

  if ($Retries -lt 1) { $Retries = 1 }
  if ($DelayMs -lt 0) { $DelayMs = 0 }

  for ($i = 1; $i -le $Retries; $i++) {
    try {
      $h = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop
      if ($null -eq $h -or [string]::IsNullOrWhiteSpace([string]$h.Hash)) { return "" }
      return ([string]$h.Hash).ToLowerInvariant()
    } catch {
      if ($i -ge $Retries) {
        Write-Verbose ("Failed to hash '{0}': {1}" -f $Path, $_.Exception.Message)
        break
      }
      if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    }
  }

  return ""
}

function Add-McccPassedHash {
  <#
  .SYNOPSIS
  Adds/updates a passed entry in the cache for the given jar file.
  #>
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Cache,
    [Parameter(Mandatory = $true)]
    [string]$JarName,
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [Parameter(Mandatory = $false)]
    [string]$Minecraft = "",
    [Parameter(Mandatory = $false)]
    [int]$HashRetries = 3,
    [Parameter(Mandatory = $false)]
    [int]$HashDelayMs = 200
  )

  if ($null -eq $Cache) { return "" }
  if (-not $Cache.ContainsKey("passed") -or -not ($Cache["passed"] -is [hashtable])) {
    $Cache["passed"] = @{}
  }

  $hash = Get-Sha256LowerHex -Path $FilePath -Retries $HashRetries -DelayMs $HashDelayMs
  if ([string]::IsNullOrWhiteSpace($hash)) { return "" }

  $nowUtc = (Get-Date).ToUniversalTime().ToString("o")
  # ! Use index lookup instead of .ContainsKey() — safe for both [hashtable] and OrderedDictionary.
  $existing = $Cache["passed"][$hash]
  $entry = $null
  if ($null -ne $existing -and $existing -is [hashtable]) {
    $entry = $existing
  } else {
    $entry = @{}
  }

  $entry["jarName"] = [string]$JarName
  if (-not [string]::IsNullOrWhiteSpace($Minecraft)) {
    $entry["minecraft"] = [string]$Minecraft
  } elseif (-not $entry.ContainsKey("minecraft")) {
    $entry["minecraft"] = ""
  }
  if (-not $entry.ContainsKey("firstSeenUtc") -or [string]::IsNullOrWhiteSpace([string]$entry["firstSeenUtc"])) {
    $entry["firstSeenUtc"] = $nowUtc
  }
  $entry["lastSeenUtc"] = $nowUtc

  $Cache["passed"][$hash] = $entry
  return $hash
}

function Test-McccHashPassed {
  [OutputType([bool])]
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Cache,
    [Parameter(Mandatory = $true)]
    [string]$Sha256LowerHex
  )

  if ($null -eq $Cache) { return $false }
  if ([string]::IsNullOrWhiteSpace($Sha256LowerHex)) { return $false }
  if (-not $Cache.ContainsKey("passed")) { return $false }
  $passedDict = $Cache["passed"]
  if ($null -eq $passedDict) { return $false }
  # ! Use index lookup instead of .ContainsKey() — safe for both [hashtable] and OrderedDictionary.
  return ($null -ne $passedDict[$Sha256LowerHex.ToLowerInvariant()])
}

