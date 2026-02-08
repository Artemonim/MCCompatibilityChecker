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

function Get-IniBool {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Ini,
    [Parameter(Mandatory = $true)]
    [string]$Section,
    [Parameter(Mandatory = $true)]
    [string]$Key,
    [Parameter(Mandatory = $false)]
    [bool]$Default = $false
  )

  $raw = Get-IniValue -Ini $Ini -Section $Section -Key $Key -Default $null
  if ([string]::IsNullOrWhiteSpace($raw)) { return [bool]$Default }

  $value = $raw.Trim().ToLowerInvariant()
  switch -Regex ($value) {
    "^(1|true|yes|y|on)$" { return $true }
    "^(0|false|no|n|off)$" { return $false }
    default { return [bool]$Default }
  }
}

function Get-ProfileOverride {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Ini,
    [Parameter(Mandatory = $true)]
    [hashtable]$BoundParameters,
    [Parameter(Mandatory = $false)]
    [string]$ProfileName = "",
    [Parameter(Mandatory = $true)]
    [hashtable]$KeyTypeMap
  )

  $overrides = @{}
  if ([string]::IsNullOrWhiteSpace($ProfileName)) { return $overrides }

  $section = ("Profile:{0}" -f $ProfileName)
  if (-not $Ini.ContainsKey($section)) { return $overrides }

  foreach ($key in $KeyTypeMap.Keys) {
    if ($BoundParameters.ContainsKey($key)) { continue }
    $raw = Get-IniValue -Ini $Ini -Section $section -Key $key -Default $null
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $type = [string]$KeyTypeMap[$key]
    switch -Regex ($type) {
      "^bool$" { $overrides[$key] = Get-IniBool -Ini $Ini -Section $section -Key $key -Default $false }
      "^int$" { $overrides[$key] = [int]$raw }
      "^string\[\]$" {
        $split = @($raw -split "," | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $overrides[$key] = $split
      }
      default { $overrides[$key] = $raw }
    }
  }

  return $overrides
}

function Initialize-McccRuntimeConfig {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StartDir,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [hashtable]$BoundParameters = $null,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$GameModsDir = "",
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$StorageModsDir = "",
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$LogPath = "",
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$LauncherExePath = "",
    [Parameter(Mandatory = $false)]
    [bool]$DefaultStorageToGame = $false,
    [Parameter(Mandatory = $false)]
    [bool]$AlwaysDefaultGameModsDir = $false,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$TreatEmptyAsUnboundKeys = @()
  )

  if ($null -eq $BoundParameters) {
    $BoundParameters = @{}
  }

  $emptyKeySet = @{}
  foreach ($key in $TreatEmptyAsUnboundKeys) {
    if ([string]::IsNullOrWhiteSpace($key)) { continue }
    $emptyKeySet[$key] = $true
  }

  $projectConfig = Import-ProjectConfig -StartDir $StartDir
  if ($projectConfig.LoadedPaths -and $projectConfig.LoadedPaths.Count -gt 0) {
    Write-Verbose ("Config loaded: {0}" -f ($projectConfig.LoadedPaths -join ", "))
  }
  $configIni = $projectConfig.Ini

  $defaultGameModsDir = Join-Path -Path ([Environment]::GetFolderPath('ApplicationData')) -ChildPath '.tlauncher\legacy\Minecraft\game\mods'
  $gameModsBound = $BoundParameters.ContainsKey("GameModsDir")
  if ($gameModsBound -and $emptyKeySet.ContainsKey("GameModsDir") -and [string]::IsNullOrWhiteSpace($GameModsDir)) {
    $gameModsBound = $false
  }
  if (-not $gameModsBound) {
    $cfgGameModsDir = Get-IniValue -Ini $configIni -Section "Paths" -Key "GameModsDir" -Default ""
    if (-not [string]::IsNullOrWhiteSpace($cfgGameModsDir)) {
      $GameModsDir = $cfgGameModsDir
    }
  }
  if (($AlwaysDefaultGameModsDir -or (-not $gameModsBound)) -and [string]::IsNullOrWhiteSpace($GameModsDir)) {
    $GameModsDir = $defaultGameModsDir
  }

  $storageBound = $BoundParameters.ContainsKey("StorageModsDir")
  if ($storageBound -and $emptyKeySet.ContainsKey("StorageModsDir") -and [string]::IsNullOrWhiteSpace($StorageModsDir)) {
    $storageBound = $false
  }
  if (-not $storageBound) {
    $StorageModsDir = Get-IniValue -Ini $configIni -Section "Paths" -Key "StorageModsDir" -Default ""
  }
  if ($DefaultStorageToGame -and [string]::IsNullOrWhiteSpace($StorageModsDir)) {
    $StorageModsDir = $GameModsDir
  }

  $logBound = $BoundParameters.ContainsKey("LogPath")
  if ($logBound -and $emptyKeySet.ContainsKey("LogPath") -and [string]::IsNullOrWhiteSpace($LogPath)) {
    $logBound = $false
  }
  if (-not $logBound) {
    $LogPath = Get-IniValue -Ini $configIni -Section "Paths" -Key "LogPath" -Default ""
  }

  $launcherBound = $BoundParameters.ContainsKey("LauncherExePath")
  if ($launcherBound -and $emptyKeySet.ContainsKey("LauncherExePath") -and [string]::IsNullOrWhiteSpace($LauncherExePath)) {
    $launcherBound = $false
  }
  if (-not $launcherBound) {
    $LauncherExePath = Get-IniValue -Ini $configIni -Section "Paths" -Key "LauncherExePath" -Default ""
  }

  $useStorage = -not [string]::IsNullOrWhiteSpace($StorageModsDir)

  return [pscustomobject]@{
    ProjectConfig = $projectConfig
    Ini = $configIni
    Paths = [pscustomobject]@{
      GameModsDir = $GameModsDir
      StorageModsDir = $StorageModsDir
      LogPath = $LogPath
      LauncherExePath = $LauncherExePath
      UseStorage = $useStorage
      DefaultGameModsDir = $defaultGameModsDir
    }
  }
}
