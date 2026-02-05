# * Shared config helpers for MCCompatibilityChecker.

function Read-IniFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw ("INI file not found: {0}" -f $Path)
  }

  $ini = @{}
  $currentSection = "default"
  $ini[$currentSection] = @{}

  $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
  foreach ($rawLine in $lines) {
    $line = [string]$rawLine
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
    if ($trimmed.StartsWith(";") -or $trimmed.StartsWith("#")) { continue }

    $sectionMatch = [regex]::Match($trimmed, "^\[(?<name>[^\]]+)\]\s*$")
    if ($sectionMatch.Success) {
      $currentSection = $sectionMatch.Groups["name"].Value.Trim()
      if ([string]::IsNullOrWhiteSpace($currentSection)) {
        $currentSection = "default"
      }
      if (-not $ini.ContainsKey($currentSection)) {
        $ini[$currentSection] = @{}
      }
      continue
    }

    $eqIndex = $trimmed.IndexOf("=")
    if ($eqIndex -lt 1) { continue }

    $key = $trimmed.Substring(0, $eqIndex).Trim()
    if ([string]::IsNullOrWhiteSpace($key)) { continue }

    $value = $trimmed.Substring($eqIndex + 1).Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      if ($value.Length -ge 2) {
        $value = $value.Substring(1, $value.Length - 2)
      }
    }

    $value = [Environment]::ExpandEnvironmentVariables($value)
    $ini[$currentSection][$key] = $value
  }

  return $ini
}

function Merge-IniMap {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Base,
    [Parameter(Mandatory = $true)]
    [hashtable]$Overlay
  )

  foreach ($section in $Overlay.Keys) {
    if (-not $Base.ContainsKey($section)) {
      $Base[$section] = @{}
    }
    foreach ($key in $Overlay[$section].Keys) {
      $Base[$section][$key] = $Overlay[$section][$key]
    }
  }
}

function Import-ProjectConfig {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StartDir,
    [Parameter(Mandatory = $false)]
    [string[]]$ConfigFileNames = @("config.ini", "config.local.ini")
  )

  $root = $null
  $dir = $StartDir
  while (-not [string]::IsNullOrWhiteSpace($dir)) {
    $agents = Join-Path -Path $dir -ChildPath "AGENTS.md"
    $scripts = Join-Path -Path $dir -ChildPath "scripts"
    if ((Test-Path -LiteralPath $agents) -and (Test-Path -LiteralPath $scripts)) {
      $root = (Resolve-Path -LiteralPath $dir).Path
      break
    }

    $parent = Split-Path -Path $dir -Parent
    if ($parent -eq $dir) { break }
    $dir = $parent
  }

  $ini = @{}
  $loaded = New-Object System.Collections.Generic.List[string]
  if ($root) {
    foreach ($name in $ConfigFileNames) {
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      $path = Join-Path -Path $root -ChildPath $name
      if (-not (Test-Path -LiteralPath $path)) { continue }

      $parsed = Read-IniFile -Path $path
      Merge-IniMap -Base $ini -Overlay $parsed
      $loaded.Add((Resolve-Path -LiteralPath $path).Path)
    }
  }

  return [pscustomobject]@{
    Root = $root
    Ini = $ini
    LoadedPaths = @($loaded.ToArray())
  }
}

function Get-IniValue {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Ini,
    [Parameter(Mandatory = $true)]
    [string]$Section,
    [Parameter(Mandatory = $true)]
    [string]$Key,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string]$Default = $null
  )

  if ($null -eq $Ini) { return $Default }
  if (-not $Ini.ContainsKey($Section)) { return $Default }
  if (-not $Ini[$Section].ContainsKey($Key)) { return $Default }
  return [string]$Ini[$Section][$Key]
}
