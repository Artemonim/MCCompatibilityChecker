<#
.SYNOPSIS
Targeted Mixin error analysis: parses crash log for Mixin failures and tries removing
the source or target mod to fix the crash cheaply (1-2 launches per error).

.DESCRIPTION
Runs BEFORE layering/isolation. Reads the current crash log, extracts Mixin errors
(`Mixin apply ... failed` and `@Mixin target ... was not found`), resolves mod IDs to
JAR files via dependency map and fallback nested-JAR scanning, and tests removal of
each candidate with a single game launch. Much faster than brute-force isolation when
the crash is caused by a broken Mixin relationship.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $false)]
  [string]$GameModsDir = "",

  [Parameter(Mandatory = $false)]
  [string]$GameLegacyFolderName = "legacy",

  [Parameter(Mandatory = $false)]
  [string]$StorageModsDir = "",

  [Parameter(Mandatory = $false)]
  [string]$StorageLegacyFolderName = "Legacy",

  [Parameter(Mandatory = $false)]
  [switch]$KeepCulpritInGameLegacy,

  [Parameter(Mandatory = $false)]
  [string]$LogPath = "",

  [Parameter(Mandatory = $false)]
  [int]$LogMaxAgeMinutes = 30,

  [Parameter(Mandatory = $false)]
  [int]$LogReadRetryCount = 5,

  [Parameter(Mandatory = $false)]
  [int]$LogReadRetryDelayMs = 500,

  [Parameter(Mandatory = $false)]
  [switch]$SkipGameLogs,

  [Parameter(Mandatory = $false)]
  [string[]]$GameProcessNames = @("javaw", "java", "Minecraft"),

  [Parameter(Mandatory = $false)]
  [int]$WaitForGameExitSeconds = 30,

  [Parameter(Mandatory = $false)]
  [int]$GameExitPollSeconds = 2,

  [Parameter(Mandatory = $false)]
  [int]$SuccessConfirmSeconds = 20,

  [Parameter(Mandatory = $false)]
  [string]$LauncherExePath = "",

  [Parameter(Mandatory = $false)]
  [string[]]$LauncherArguments = @(),

  [Parameter(Mandatory = $false)]
  [Alias("Auto")]
  [switch]$UseAutoLaunch,

  [Parameter(Mandatory = $false)]
  [string]$LauncherWindowTitlePattern = "Legacy Launcher",

  [Parameter(Mandatory = $false)]
  [string[]]$PlayButtonNames = @("Запустить", "Play", "Start"),

  [Parameter(Mandatory = $false)]
  [int]$PlayClickOffsetX = -1,

  [Parameter(Mandatory = $false)]
  [int]$PlayClickOffsetY = -1,

  [Parameter(Mandatory = $false)]
  [int]$PlayClickDelayMs = 1000,

  [Parameter(Mandatory = $false)]
  [int]$LaunchStartTimeoutSeconds = 15,

  [Parameter(Mandatory = $false)]
  [int]$PlayClickMaxAttempts = 2,

  [Parameter(Mandatory = $false)]
  [bool]$RequireGameStartForTimeout = $true,

  [Parameter(Mandatory = $false)]
  [bool]$UseEnterFallback = $true,

  [Parameter(Mandatory = $false)]
  [bool]$EnableBroadUiSearch = $false,

  [Parameter(Mandatory = $false)]
  [string[]]$CrashWindowTitlePatterns = @("Что-то сломалось"),

  [Parameter(Mandatory = $false)]
  [string[]]$FabricWindowTitlePatterns = @("Fabric Loader", "owo-sentinel"),

  [Parameter(Mandatory = $false)]
  [int]$CrashCloseClickOffsetX = -1,

  [Parameter(Mandatory = $false)]
  [int]$CrashCloseClickOffsetY = -1,

  [Parameter(Mandatory = $false)]
  [int]$CrashCloseDelaySeconds = 5,

  [Parameter(Mandatory = $false)]
  [int]$LauncherWindowTimeoutSeconds = 60,

  [Parameter(Mandatory = $false)]
  [int]$OutcomeTimeoutSeconds = 20,

  [Parameter(Mandatory = $false)]
  [int]$PollIntervalSeconds = 2,

  [Parameter(Mandatory = $false)]
  [ValidateSet("Tool", "File", "Internal")]
  [string]$DependencyMapSource = "Tool",

  [Parameter(Mandatory = $false)]
  [string]$DependencyMapJsonPath = "",

  [Parameter(Mandatory = $false)]
  [string]$DependencyMapToolPath = "",

  [Parameter(Mandatory = $false)]
  [string]$DependencyMapOutDir = "",

  [Parameter(Mandatory = $false)]
  [switch]$EmitResultObject,

  [Parameter(Mandatory = $false)]
  [int]$MoveRetryCount = 15,

  [Parameter(Mandatory = $false)]
  [int]$MoveRetryDelayMs = 1000,

  [Parameter(Mandatory = $false)]
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# * Launch wait scaling config.
$launchWaitBaseSeconds = 20
$launchWaitPerModSeconds = 0.1

function Get-ActiveModCount {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModsDir
  )

  if ([string]::IsNullOrWhiteSpace($ModsDir)) { return 0 }
  if (-not (Test-Path -LiteralPath $ModsDir)) { return 0 }
  $mods = Get-ChildItem -LiteralPath $ModsDir -Filter "*.jar" -File -ErrorAction SilentlyContinue
  if ($null -eq $mods) { return 0 }
  return @($mods).Count
}

function Get-ScaledLaunchWaitTime {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ActiveModCount,
    [Parameter(Mandatory = $true)]
    [double]$PerModSeconds,
    [Parameter(Mandatory = $true)]
    [int]$BaseSeconds
  )

  $rawSeconds = $BaseSeconds + ($ActiveModCount * $PerModSeconds)
  $scaledSeconds = [int][Math]::Ceiling($rawSeconds)
  if ($scaledSeconds -lt $BaseSeconds) { $scaledSeconds = $BaseSeconds }
  return $scaledSeconds
}

$useDynamicOutcomeTimeout = -not $PSBoundParameters.ContainsKey("OutcomeTimeoutSeconds")
$useDynamicSuccessConfirm = -not $PSBoundParameters.ContainsKey("SuccessConfirmSeconds")

# ────────────────────────────────────────────────────────────────────────────
# * Load shared modules.
# ────────────────────────────────────────────────────────────────────────────

$sharedConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Config.ps1"
. $sharedConfigPath
$sharedUiPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LauncherUi.ps1"
. $sharedUiPath
$sharedLauncherPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Launcher.ps1"
. $sharedLauncherPath
$sharedLogParsingPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-LogParsing.ps1"
. $sharedLogParsingPath
$sharedJarDepPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-JarDependencies.ps1"
. $sharedJarDepPath
$sharedLogPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LogTools.ps1"
if (-not (Test-Path -LiteralPath $sharedLogPath)) { throw ("Shared log helpers not found: {0}" -f $sharedLogPath) }
. $sharedLogPath

$projectConfig = Import-ProjectConfig -StartDir $PSScriptRoot
$configIni = $projectConfig.Ini

if ([string]::IsNullOrWhiteSpace($GameModsDir)) {
  $GameModsDir = Get-IniValue -Ini $configIni -Section "Paths" -Key "GameModsDir" -Default (Join-Path -Path ([Environment]::GetFolderPath('ApplicationData')) -ChildPath '.tlauncher\legacy\Minecraft\game\mods')
}
if ([string]::IsNullOrWhiteSpace($StorageModsDir)) {
  $StorageModsDir = Get-IniValue -Ini $configIni -Section "Paths" -Key "StorageModsDir" -Default ""
}
$useStorage = -not [string]::IsNullOrWhiteSpace($StorageModsDir)

function Add-FirstLookupValue {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Map,
    [Parameter(Mandatory = $true)]
    [string]$Key,
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Key) -or [string]::IsNullOrWhiteSpace($Value)) { return }
  $k = $Key.Trim().ToLowerInvariant()
  if (-not $Map.ContainsKey($k)) {
    $Map[$k] = $Value
  }
}

function Add-MixinConfigLookupValue {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Map,
    [Parameter(Mandatory = $true)]
    [string]$ConfigName,
    [Parameter(Mandatory = $true)]
    [string]$JarName
  )

  if ([string]::IsNullOrWhiteSpace($ConfigName) -or [string]::IsNullOrWhiteSpace($JarName)) { return }
  $normalized = $ConfigName.Trim().Replace("\", "/")
  if ([string]::IsNullOrWhiteSpace($normalized)) { return }
  Add-FirstLookupValue -Map $Map -Key $normalized -Value $JarName

  $fileName = $normalized
  $slashIndex = $normalized.LastIndexOf("/")
  if ($slashIndex -ge 0 -and $slashIndex + 1 -lt $normalized.Length) {
    $fileName = $normalized.Substring($slashIndex + 1)
  }
  Add-FirstLookupValue -Map $Map -Key $fileName -Value $JarName
}

function Get-ModIdsFromModJson {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$ModJson
  )

  $ids = New-Object System.Collections.Generic.List[string]
  if ($null -eq $ModJson) { return @() }

  if ($ModJson.PSObject.Properties.Name -contains "id") {
    $mainId = [string]$ModJson.id
    if (-not [string]::IsNullOrWhiteSpace($mainId)) {
      $ids.Add($mainId) | Out-Null
    }
  }

  if ($ModJson.PSObject.Properties.Name -contains "provides" -and $null -ne $ModJson.provides) {
    if ($ModJson.provides -is [string]) {
      $v = [string]$ModJson.provides
      if (-not [string]::IsNullOrWhiteSpace($v)) { $ids.Add($v) | Out-Null }
    } elseif ($ModJson.provides -is [System.Collections.IDictionary]) {
      foreach ($key in $ModJson.provides.Keys) {
        $v = [string]$key
        if (-not [string]::IsNullOrWhiteSpace($v)) { $ids.Add($v) | Out-Null }
      }
    } elseif ($ModJson.provides -is [pscustomobject]) {
      foreach ($prop in $ModJson.provides.PSObject.Properties) {
        $v = [string]$prop.Name
        if (-not [string]::IsNullOrWhiteSpace($v)) { $ids.Add($v) | Out-Null }
      }
    } elseif ($ModJson.provides -is [System.Collections.IEnumerable]) {
      foreach ($item in $ModJson.provides) {
        $v = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($v)) { $ids.Add($v) | Out-Null }
      }
    }
  }

  return @($ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
}

function Get-MixinConfigNamesFromValue {
  param(
    [Parameter(Mandatory = $false)]
    $Value
  )

  $results = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Value) { return @() }

  $queue = New-Object System.Collections.Queue
  $queue.Enqueue($Value)

  while ($queue.Count -gt 0) {
    $item = $queue.Dequeue()
    if ($null -eq $item) { continue }

    if ($item -is [string]) {
      $name = [string]$item
      if (-not [string]::IsNullOrWhiteSpace($name)) {
        $results.Add($name.Trim()) | Out-Null
      }
      continue
    }

    if ($item -is [System.Collections.IDictionary]) {
      foreach ($dictValue in $item.Values) {
        $queue.Enqueue($dictValue)
      }
      continue
    }

    if ($item -is [pscustomobject]) {
      if ($item.PSObject.Properties.Name -contains "config") {
        $queue.Enqueue($item.config)
        continue
      }
      if ($item.PSObject.Properties.Name -contains "file") {
        $queue.Enqueue($item.file)
        continue
      }
      foreach ($prop in $item.PSObject.Properties) {
        $queue.Enqueue($prop.Value)
      }
      continue
    }

    if ($item -is [System.Collections.IEnumerable] -and -not ($item -is [string])) {
      foreach ($entry in $item) {
        $queue.Enqueue($entry)
      }
    }
  }

  return @($results | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Get-NestedJarEntryPathsFromModJson {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$ModJson
  )

  if ($null -eq $ModJson) { return @() }
  if (-not ($ModJson.PSObject.Properties.Name -contains "jars")) { return @() }
  if ($null -eq $ModJson.jars) { return @() }

  $result = New-Object System.Collections.Generic.List[string]
  $jarsValue = $ModJson.jars

  if ($jarsValue -is [string]) {
    $v = [string]$jarsValue
    if (-not [string]::IsNullOrWhiteSpace($v)) { $result.Add($v.Trim()) | Out-Null }
  } elseif ($jarsValue -is [System.Collections.IEnumerable]) {
    foreach ($entry in $jarsValue) {
      if ($null -eq $entry) { continue }
      if ($entry -is [string]) {
        $v = [string]$entry
        if (-not [string]::IsNullOrWhiteSpace($v)) { $result.Add($v.Trim()) | Out-Null }
        continue
      }
      if ($entry -is [System.Collections.IDictionary]) {
        if ($entry.Contains("file")) {
          $v = [string]$entry["file"]
          if (-not [string]::IsNullOrWhiteSpace($v)) { $result.Add($v.Trim()) | Out-Null }
        }
        continue
      }
      if ($entry -is [pscustomobject]) {
        if ($entry.PSObject.Properties.Name -contains "file") {
          $v = [string]$entry.file
          if (-not [string]::IsNullOrWhiteSpace($v)) { $result.Add($v.Trim()) | Out-Null }
        }
        continue
      }
    }
  }

  return @($result | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Replace("\", "/") } | Sort-Object -Unique)
}

function Get-FabricMetadataFromZipArchive {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.Compression.ZipArchive]$Zip
  )

  $fabricText = Get-JarZipEntryText -Zip $Zip -EntryPath "fabric.mod.json"
  if ([string]::IsNullOrWhiteSpace($fabricText)) { return $null }

  $modJson = $null
  try {
    $modJson = $fabricText | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }

  $modIds = @(Get-ModIdsFromModJson -ModJson $modJson)
  $mixinConfigs = @()
  if ($modJson.PSObject.Properties.Name -contains "mixins") {
    $mixinConfigs = @(Get-MixinConfigNamesFromValue -Value $modJson.mixins)
  }
  $nestedJarEntries = @(Get-NestedJarEntryPathsFromModJson -ModJson $modJson)

  return [pscustomobject]@{
    ModIds           = @($modIds)
    MixinConfigs     = @($mixinConfigs)
    NestedJarEntries = @($nestedJarEntries)
  }
}

function Add-MixinConfigEntriesFromZipArchive {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.Compression.ZipArchive]$Zip,
    [Parameter(Mandatory = $true)]
    [hashtable]$MixinConfigToJar,
    [Parameter(Mandatory = $true)]
    [string]$JarName
  )

  foreach ($entry in @($Zip.Entries)) {
    if ($null -eq $entry) { continue }
    $entryName = [string]$entry.FullName
    if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
    $entryLower = $entryName.ToLowerInvariant()
    if ($entryLower.EndsWith(".json") -and $entryLower.Contains("mixin")) {
      Add-MixinConfigLookupValue -Map $MixinConfigToJar -ConfigName $entryName -JarName $JarName
    }
  }
}

function Build-MixinFallbackLookup {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModsDir
  )

  $modIdToJar = @{}
  $mixinConfigToJar = @{}
  $knownModIds = @{}

  if ([string]::IsNullOrWhiteSpace($ModsDir) -or -not (Test-Path -LiteralPath $ModsDir)) {
    return [pscustomobject]@{
      ModIdToJar       = $modIdToJar
      MixinConfigToJar = $mixinConfigToJar
      KnownModIds      = $knownModIds
    }
  }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $jarFiles = Get-ChildItem -LiteralPath $ModsDir -Filter "*.jar" -File -ErrorAction SilentlyContinue |
    Sort-Object -Property @{ Expression = { $_.LastWriteTime }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false }

  foreach ($jarFile in @($jarFiles)) {
    if ($null -eq $jarFile) { continue }
    $jarName = [string]$jarFile.Name
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }

    $zip = $null
    try {
      $zip = [System.IO.Compression.ZipFile]::OpenRead($jarFile.FullName)
      if ($null -eq $zip) { continue }

      $outerMeta = Get-FabricMetadataFromZipArchive -Zip $zip
      if ($null -ne $outerMeta) {
        foreach ($mid in @($outerMeta.ModIds)) {
          $id = [string]$mid
          if ([string]::IsNullOrWhiteSpace($id)) { continue }
          Add-FirstLookupValue -Map $modIdToJar -Key $id -Value $jarName
          $knownModIds[$id.ToLowerInvariant()] = $true
        }
        foreach ($mix in @($outerMeta.MixinConfigs)) {
          Add-MixinConfigLookupValue -Map $mixinConfigToJar -ConfigName ([string]$mix) -JarName $jarName
        }

        $entryByLower = @{}
        foreach ($entry in @($zip.Entries)) {
          if ($null -eq $entry) { continue }
          $entryName = [string]$entry.FullName
          if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
          $entryByLower[$entryName.Replace("\", "/").ToLowerInvariant()] = $entry
        }

        foreach ($nestedEntryPath in @($outerMeta.NestedJarEntries)) {
          $nestedKey = [string]$nestedEntryPath
          if ([string]::IsNullOrWhiteSpace($nestedKey)) { continue }
          $nestedKey = $nestedKey.Replace("\", "/").ToLowerInvariant()
          if (-not $entryByLower.ContainsKey($nestedKey)) { continue }

          $nestedEntry = $entryByLower[$nestedKey]
          if ($null -eq $nestedEntry) { continue }

          $nestedStream = $null
          $memoryStream = $null
          $nestedZip = $null
          try {
            $nestedStream = $nestedEntry.Open()
            $memoryStream = New-Object System.IO.MemoryStream
            $nestedStream.CopyTo($memoryStream)
            $memoryStream.Position = 0

            $nestedZip = [System.IO.Compression.ZipArchive]::new($memoryStream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
            $nestedMeta = Get-FabricMetadataFromZipArchive -Zip $nestedZip
            if ($null -ne $nestedMeta) {
              foreach ($mid in @($nestedMeta.ModIds)) {
                $id = [string]$mid
                if ([string]::IsNullOrWhiteSpace($id)) { continue }
                Add-FirstLookupValue -Map $modIdToJar -Key $id -Value $jarName
                $knownModIds[$id.ToLowerInvariant()] = $true
              }
              foreach ($mix in @($nestedMeta.MixinConfigs)) {
                Add-MixinConfigLookupValue -Map $mixinConfigToJar -ConfigName ([string]$mix) -JarName $jarName
              }
            }

            Add-MixinConfigEntriesFromZipArchive -Zip $nestedZip -MixinConfigToJar $mixinConfigToJar -JarName $jarName
          } catch {
            continue
          } finally {
            if ($null -ne $nestedZip) { $nestedZip.Dispose() }
            if ($null -ne $nestedStream) { $nestedStream.Dispose() }
            if ($null -ne $memoryStream) { $memoryStream.Dispose() }
          }
        }
      }

      Add-MixinConfigEntriesFromZipArchive -Zip $zip -MixinConfigToJar $mixinConfigToJar -JarName $jarName
    } catch {
      continue
    } finally {
      if ($null -ne $zip) { $zip.Dispose() }
    }
  }

  return [pscustomobject]@{
    ModIdToJar       = $modIdToJar
    MixinConfigToJar = $mixinConfigToJar
    KnownModIds      = $knownModIds
  }
}

function Get-ModIdLookupVariant {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModId
  )

  $variants = @{}
  if ([string]::IsNullOrWhiteSpace($ModId)) { return @() }
  $id = $ModId.Trim().ToLowerInvariant()
  $variants[$id] = $true
  $variants[$id.Replace("-", "_")] = $true
  $variants[$id.Replace("_", "-")] = $true

  if ($id -match '[_\-]mixin$') {
    $base = [regex]::Replace($id, '[_\-]mixin$', '')
    if (-not [string]::IsNullOrWhiteSpace($base)) {
      $variants[$base] = $true
      $variants[("{0}_modloader" -f $base)] = $true
      $variants[("{0}-modloader" -f $base)] = $true
    }
  }

  if ($id -match '[_\-]modloader$') {
    $base = [regex]::Replace($id, '[_\-]modloader$', '')
    if (-not [string]::IsNullOrWhiteSpace($base)) {
      $variants[$base] = $true
      $variants[("{0}_mixin" -f $base)] = $true
      $variants[("{0}-mixin" -f $base)] = $true
    }
  }

  return ,@($variants.Keys | Sort-Object)
}

function Resolve-MixinCandidateJarName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModId,
    [Parameter(Mandatory = $false)]
    [string]$MixinJson = "",
    [Parameter(Mandatory = $true)]
    [hashtable]$PrimaryModIdToJar,
    [Parameter(Mandatory = $true)]
    [hashtable]$FallbackModIdToJar,
    [Parameter(Mandatory = $true)]
    [hashtable]$FallbackMixinConfigToJar
  )

  $id = [string]$ModId
  if (-not [string]::IsNullOrWhiteSpace($id)) {
    $key = $id.ToLowerInvariant()
    if ($PrimaryModIdToJar.ContainsKey($key)) { return [string]$PrimaryModIdToJar[$key] }
    if ($FallbackModIdToJar.ContainsKey($key)) { return [string]$FallbackModIdToJar[$key] }

    foreach ($variant in @(Get-ModIdLookupVariant -ModId $key)) {
      if ($PrimaryModIdToJar.ContainsKey($variant)) { return [string]$PrimaryModIdToJar[$variant] }
      if ($FallbackModIdToJar.ContainsKey($variant)) { return [string]$FallbackModIdToJar[$variant] }
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($MixinJson)) {
    $mixKey = $MixinJson.Trim().Replace("\", "/").ToLowerInvariant()
    if ($FallbackMixinConfigToJar.ContainsKey($mixKey)) {
      return [string]$FallbackMixinConfigToJar[$mixKey]
    }

    $fileName = $mixKey
    $slashIndex = $mixKey.LastIndexOf("/")
    if ($slashIndex -ge 0 -and $slashIndex + 1 -lt $mixKey.Length) {
      $fileName = $mixKey.Substring($slashIndex + 1)
    }
    if ($FallbackMixinConfigToJar.ContainsKey($fileName)) {
      return [string]$FallbackMixinConfigToJar[$fileName]
    }
  }

  return $null
}

# ────────────────────────────────────────────────────────────────────────────
# * Read crash log.
# ────────────────────────────────────────────────────────────────────────────

$logSnapshot = Get-ConfiguredLogSnapshot
if ($null -eq $logSnapshot -or $logSnapshot.Lines.Count -eq 0) {
  Write-Host "Mixin analysis: no crash log available." -ForegroundColor Gray
  if ($EmitResultObject) {
    Write-Output ([pscustomobject]@{ Type = "MixinAnalysisResult"; CulpritJarNames = @(); CulpritMoves = @(); Resolved = $false })
  }
  exit 0
}

$mixinApplyErrors = Get-MixinApplyErrorsFromLog -Lines $logSnapshot.Lines
$mixinTargetErrors = Get-MixinErrorsFromLog -Lines $logSnapshot.Lines
if ($mixinApplyErrors.Count -eq 0 -and $mixinTargetErrors.Count -eq 0) {
  Write-Host "Mixin analysis: no supported Mixin errors found in crash log." -ForegroundColor Gray
  if ($EmitResultObject) {
    Write-Output ([pscustomobject]@{ Type = "MixinAnalysisResult"; CulpritJarNames = @(); CulpritMoves = @(); Resolved = $false })
  }
  exit 0
}

$mixinErrors = New-Object System.Collections.Generic.List[pscustomobject]
$seenMixinErrorKeys = @{}
foreach ($mx in $mixinApplyErrors) {
  $key = ("apply|{0}|{1}|{2}" -f $mx.SourceModId, $mx.TargetClass, $mx.MixinJson).ToLowerInvariant()
  if ($seenMixinErrorKeys.ContainsKey($key)) { continue }
  $seenMixinErrorKeys[$key] = $true
  $mixinErrors.Add([pscustomobject]@{
      ErrorKind   = "apply_failed"
      SourceModId = $mx.SourceModId
      TargetClass = $mx.TargetClass
      MixinJson   = $mx.MixinJson
      MixinClass  = $mx.MixinClass
      ErrorLine   = $mx.ErrorLine
    })
}
foreach ($mx in $mixinTargetErrors) {
  $key = ("target|{0}|{1}|{2}" -f $mx.SourceModId, $mx.TargetClass, $mx.MixinJson).ToLowerInvariant()
  if ($seenMixinErrorKeys.ContainsKey($key)) { continue }
  $seenMixinErrorKeys[$key] = $true
  $mixinErrors.Add([pscustomobject]@{
      ErrorKind   = "target_missing"
      SourceModId = $mx.SourceModId
      TargetClass = $mx.TargetClass
      MixinJson   = $mx.MixinJson
      MixinClass  = $mx.MixinClass
      ErrorLine   = $mx.ErrorLine
    })
}

Write-Host ("Mixin analysis: found {0} Mixin apply failure(s), {1} @Mixin target error(s); total: {2}" -f $mixinApplyErrors.Count, $mixinTargetErrors.Count, $mixinErrors.Count) -ForegroundColor Cyan

# ────────────────────────────────────────────────────────────────────────────
# * Load dependency map for mod ID → JAR resolution.
# ────────────────────────────────────────────────────────────────────────────

$dependencyMap = Get-DependencyMapFromSource -ScanPath $GameModsDir

# * Build mod ID → JAR name lookup and known mod IDs set.
$modIdToJar = @{}
$knownModIds = @{}
if ($null -eq $dependencyMap) {
  Write-Host "Mixin analysis: dependency map unavailable. Falling back to direct JAR metadata scan." -ForegroundColor Yellow
} else {
  foreach ($mod in @($dependencyMap.Mods)) {
    if ($null -eq $mod) { continue }
    $id = [string]$mod.ModId
    $jar = [string]$mod.JarName
    if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($jar)) { continue }
    $modIdToJar[$id.ToLowerInvariant()] = $jar
    $knownModIds[$id.ToLowerInvariant()] = $true
    foreach ($providedId in @($mod.ProvidedModIds)) {
      $p = [string]$providedId
      if (-not [string]::IsNullOrWhiteSpace($p)) {
        $modIdToJar[$p.ToLowerInvariant()] = $jar
        $knownModIds[$p.ToLowerInvariant()] = $true
      }
    }
  }
}

$fallbackLookup = Build-MixinFallbackLookup -ModsDir $GameModsDir
$fallbackModIdToJar = @{}
$fallbackMixinConfigToJar = @{}
if ($null -ne $fallbackLookup -and $null -ne $fallbackLookup.ModIdToJar) {
  $fallbackModIdToJar = $fallbackLookup.ModIdToJar
}
if ($null -ne $fallbackLookup -and $null -ne $fallbackLookup.MixinConfigToJar) {
  $fallbackMixinConfigToJar = $fallbackLookup.MixinConfigToJar
}

foreach ($entry in @($fallbackModIdToJar.GetEnumerator())) {
  $id = [string]$entry.Key
  $jar = [string]$entry.Value
  if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($jar)) { continue }
  if (-not $modIdToJar.ContainsKey($id)) {
    $modIdToJar[$id] = $jar
  }
  $knownModIds[$id] = $true
}
if ($null -ne $fallbackLookup -and $null -ne $fallbackLookup.KnownModIds) {
  foreach ($id in @($fallbackLookup.KnownModIds.Keys)) {
    $k = [string]$id
    if (-not [string]::IsNullOrWhiteSpace($k)) {
      $knownModIds[$k.ToLowerInvariant()] = $true
    }
  }
}

if ($modIdToJar.Count -eq 0 -and $fallbackMixinConfigToJar.Count -eq 0) {
  Write-Host "Mixin analysis: no mod/jar lookup data available. Skipping targeted checks." -ForegroundColor Yellow
  if ($EmitResultObject) {
    Write-Output ([pscustomobject]@{ Type = "MixinAnalysisResult"; CulpritJarNames = @(); CulpritMoves = @(); Resolved = $false })
  }
  exit 0
}

# ────────────────────────────────────────────────────────────────────────────
# * Resolve candidates and test targeted removal.
# ────────────────────────────────────────────────────────────────────────────

$mcVersionForLegacy = Get-MinecraftVersionFromLog -Lines $logSnapshot.Lines
if ([string]::IsNullOrWhiteSpace($mcVersionForLegacy)) { $mcVersionForLegacy = "unknown" }

$storageLegacyVersionDir = $null
if ($useStorage) {
  $storageLegacyRoot = Join-Path -Path $StorageModsDir -ChildPath $StorageLegacyFolderName
  $storageLegacyVersionDir = Join-Path -Path $storageLegacyRoot -ChildPath $mcVersionForLegacy
}
$gameLegacyVersionDir = $null
if ($KeepCulpritInGameLegacy) {
  $gameLegacyRoot = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
  $gameLegacyVersionDir = Join-Path -Path $gameLegacyRoot -ChildPath $mcVersionForLegacy
}

$culpritJarNames = New-Object System.Collections.Generic.List[string]
$culpritMoves = New-Object System.Collections.Generic.List[pscustomobject]
$mixinConflicts = New-Object System.Collections.Generic.List[pscustomobject]
$resolved = $false

foreach ($mxErr in $mixinErrors) {
  # * Resolve source mod JAR.
  $sourceJar = Resolve-MixinCandidateJarName `
    -ModId $mxErr.SourceModId `
    -MixinJson $mxErr.MixinJson `
    -PrimaryModIdToJar $modIdToJar `
    -FallbackModIdToJar $fallbackModIdToJar `
    -FallbackMixinConfigToJar $fallbackMixinConfigToJar

  # * Resolve target mod JAR (heuristic: match class segments against known mod IDs).
  $targetModId = $null
  $isMinecraftTargetClass = (-not [string]::IsNullOrWhiteSpace($mxErr.TargetClass)) -and $mxErr.TargetClass.ToLowerInvariant().StartsWith("net.minecraft.")
  if (-not [string]::IsNullOrWhiteSpace($mxErr.TargetClass) -and (-not $isMinecraftTargetClass)) {
    $targetModId = Resolve-ModIdFromClassName -ClassName $mxErr.TargetClass -KnownModIds $knownModIds
  }
  $targetJar = $null
  if ($null -ne $targetModId) {
    $targetJar = Resolve-MixinCandidateJarName `
      -ModId $targetModId `
      -PrimaryModIdToJar $modIdToJar `
      -FallbackModIdToJar $fallbackModIdToJar `
      -FallbackMixinConfigToJar $fallbackMixinConfigToJar
  }

  # * Collect conflict info for every Mixin error regardless of resolution outcome.
  $mixinConflicts.Add([pscustomobject]@{
      ErrorKind    = $mxErr.ErrorKind
      SourceModId  = $mxErr.SourceModId
      SourceJar    = if ($null -ne $sourceJar) { $sourceJar } else { "" }
      TargetClass  = $mxErr.TargetClass
      TargetModId  = if ($null -ne $targetModId) { $targetModId } else { "" }
      TargetJar    = if ($null -ne $targetJar) { $targetJar } else { "" }
      MixinJson    = if (-not [string]::IsNullOrWhiteSpace($mxErr.MixinJson)) { $mxErr.MixinJson } else { "" }
      MixinClass   = if (-not [string]::IsNullOrWhiteSpace($mxErr.MixinClass)) { $mxErr.MixinClass } else { "" }
      ErrorLine    = $mxErr.ErrorLine
    })

  if ($mxErr.ErrorKind -eq "apply_failed") {
    Write-Host ("  Mixin apply failed: mod '{0}' → class '{1}' (config: {2})" -f $mxErr.SourceModId, $mxErr.TargetClass, $mxErr.MixinJson) -ForegroundColor Gray
  } else {
    Write-Host ("  @Mixin target missing: mod '{0}' → class '{1}'" -f $mxErr.SourceModId, $mxErr.TargetClass) -ForegroundColor Gray
  }
  if ($null -ne $sourceJar) { Write-Host ("    Source JAR: {0}" -f $sourceJar) -ForegroundColor Gray }
  if ($null -ne $targetJar) { Write-Host ("    Target JAR: {0} (mod: {1})" -f $targetJar, $targetModId) -ForegroundColor Gray }

  # * Try candidates: source first, then target.
  $candidates = @()
  if ($null -ne $sourceJar) { $candidates += $sourceJar }
  $allowTargetCandidate = ($null -ne $targetJar -and $targetJar -ne $sourceJar)
  if ($allowTargetCandidate -and $mxErr.ErrorKind -eq "apply_failed") {
    if ($isMinecraftTargetClass -or $targetModId -in @("minecraft", "java", "fabricloader")) {
      $allowTargetCandidate = $false
    }
  }
  if ($allowTargetCandidate) { $candidates += $targetJar }

  foreach ($candJar in $candidates) {
    $gamePath = Join-Path -Path $GameModsDir -ChildPath $candJar
    if (-not (Test-Path -LiteralPath $gamePath)) {
      Write-Host ("    Skipping {0}: not found in game mods." -f $candJar) -ForegroundColor Gray
      continue
    }

    Write-Host ("    Testing removal of: {0}" -f $candJar) -ForegroundColor Cyan

    if ($DryRun) {
      Write-Host "    DRYRUN: would remove and test." -ForegroundColor Gray
      continue
    }

    # * Quarantine the candidate.
    $tempDir = Join-Path -Path $GameModsDir -ChildPath ("{0}\temp\mixin-{1}" -f $GameLegacyFolderName, (Get-Date -Format "yyyyMMdd-HHmmss"))
    if (-not (Test-Path -LiteralPath $tempDir)) {
      New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    $tempDest = Join-Path -Path $tempDir -ChildPath $candJar
    Move-Item -LiteralPath $gamePath -Destination $tempDest -Force

    $storageTemp = $null
    $storagePath = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $candJar } else { $null }
    if ($useStorage -and $storagePath -and (Test-Path -LiteralPath $storagePath)) {
      $storageTemp = Join-Path -Path $tempDir -ChildPath ("storage-{0}" -f $candJar)
      Move-Item -LiteralPath $storagePath -Destination $storageTemp -Force
    }

    $isSuccess = $false
    $launchStart = $null
    try {
      # * Close any stray crash dialogs.
      $strayCrash = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
      if ($null -ne $strayCrash) {
        Write-Host ("    Closing stray crash dialog: {0}" -f $strayCrash.Title) -ForegroundColor Gray
        Invoke-WindowClose -Handle $strayCrash.Handle
        Start-Sleep -Seconds 2
      }

      # * Launch game.
      $effectiveConfirmSeconds = $SuccessConfirmSeconds
      if ($useDynamicOutcomeTimeout -or $useDynamicSuccessConfirm) {
        $activeModCount = Get-ActiveModCount -ModsDir $GameModsDir
        $scaledLaunchSeconds = Get-ScaledLaunchWaitTime -ActiveModCount $activeModCount `
          -PerModSeconds $launchWaitPerModSeconds `
          -BaseSeconds $launchWaitBaseSeconds
        if ($useDynamicOutcomeTimeout) { $OutcomeTimeoutSeconds = $scaledLaunchSeconds }
        if ($useDynamicSuccessConfirm) { $effectiveConfirmSeconds = $scaledLaunchSeconds }
      }

      $launchStart = Get-Date
      $outcome = Invoke-ConfiguredLaunchAttempt
      Write-Host ("    Outcome: {0}" -f $outcome.Type) -ForegroundColor Gray

      if ($outcome.Type -eq "Timeout") {
        # * Wait for stability confirmation.
        Write-Host ("    Confirming stability ({0}s)..." -f $effectiveConfirmSeconds) -ForegroundColor Gray
        Start-Sleep -Seconds $effectiveConfirmSeconds
        $crashNow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
        if ($null -eq $crashNow) {
          $isSuccess = $true
        } else {
          Invoke-WindowClose -Handle $crashNow.Handle
        }
        # * Kill game process.
        [void](Stop-ConfiguredGameProcess -StartedAfter $launchStart)
      }

      if ($outcome.Type -eq "CrashDialog" -and $null -ne $outcome.Window) {
        Invoke-WindowClose -Handle $outcome.Window.Handle
      }
      if ($outcome.Type -eq "FabricDialog" -and $null -ne $outcome.Window) {
        Invoke-WindowClose -Handle $outcome.Window.Handle
      }

      # * Close post-outcome crash dialogs.
      Start-Sleep -Seconds 2
      $postCrash = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
      if ($null -ne $postCrash) {
        Invoke-WindowClose -Handle $postCrash.Handle
      }
    } catch {
      # ! Error during launch/test — restore quarantined mod and re-throw.
      Write-Host ("    Error during Mixin test: {0}. Rolling back." -f $_.Exception.Message) -ForegroundColor Red
      if (Test-Path -LiteralPath $tempDest) {
        Move-Item -LiteralPath $tempDest -Destination $gamePath -Force -ErrorAction SilentlyContinue
      }
      if ($null -ne $storageTemp -and (Test-Path -LiteralPath $storageTemp) -and $null -ne $storagePath) {
        Move-Item -LiteralPath $storageTemp -Destination $storagePath -Force -ErrorAction SilentlyContinue
      }
      throw
    } finally {
      if ($null -ne $launchStart) {
        [void](Stop-ConfiguredGameProcess -StartedAfter $launchStart)
        [void](Wait-ConfiguredGameExit -StartedAfter $launchStart -WarningContext "Mixin analysis cleanup")
      }
    }

    if ($isSuccess) {
      Write-Host ("    Confirmed: removing {0} fixes the Mixin crash." -f $candJar) -ForegroundColor Green

      # * Move to legacy.
      $culpritStorageLegacy = $null
      $culpritGameLegacy = $null

      if ($useStorage -and $null -ne $storageLegacyVersionDir) {
        if (-not (Test-Path -LiteralPath $storageLegacyVersionDir)) {
          New-Item -ItemType Directory -Path $storageLegacyVersionDir -Force | Out-Null
        }
        $srcFile = if ($null -ne $storageTemp -and (Test-Path -LiteralPath $storageTemp)) { $storageTemp } else { $tempDest }
        $destPath = Join-Path -Path $storageLegacyVersionDir -ChildPath $candJar
        Copy-Item -LiteralPath $srcFile -Destination $destPath -Force
        $culpritStorageLegacy = $destPath
        Write-Host ("Moved culprit to storage legacy: {0}" -f $destPath) -ForegroundColor Green
        $legacyLogEntry = "Moved culprit to storage legacy: {0}" -f $destPath
        Add-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "legacy.log") -Value $legacyLogEntry -ErrorAction SilentlyContinue
      }

      if ($KeepCulpritInGameLegacy -and $null -ne $gameLegacyVersionDir) {
        if (-not (Test-Path -LiteralPath $gameLegacyVersionDir)) {
          New-Item -ItemType Directory -Path $gameLegacyVersionDir -Force | Out-Null
        }
        $destPath = Join-Path -Path $gameLegacyVersionDir -ChildPath $candJar
        Move-Item -LiteralPath $tempDest -Destination $destPath -Force
        $culpritGameLegacy = $destPath
        Write-Host ("Moved culprit to game legacy: {0}" -f $destPath) -ForegroundColor Green
      }

      # * Clean up temp storage copy.
      if ($null -ne $storageTemp -and (Test-Path -LiteralPath $storageTemp)) {
        Remove-Item -LiteralPath $storageTemp -Force -ErrorAction SilentlyContinue
      }
      # * Clean up temp game copy if not already moved.
      if (Test-Path -LiteralPath $tempDest) {
        Remove-Item -LiteralPath $tempDest -Force -ErrorAction SilentlyContinue
      }

      $culpritJarNames.Add($candJar)
      $culpritMoves.Add([pscustomobject]@{
          JarName            = $candJar
          GameModsDir        = $GameModsDir
          StorageModsDir     = if ($useStorage) { $StorageModsDir } else { "" }
          StorageLegacyPath  = $culpritStorageLegacy
          GameLegacyPath     = $culpritGameLegacy
          Minecraft          = $mcVersionForLegacy
          KeepCulpritInGameLegacy = [bool]$KeepCulpritInGameLegacy
          CrashEvidenceKey   = $mxErr.ErrorLine
          Stage              = "mixin-analysis"
        })
      Write-Host ("Culprit identified: {0}" -f $candJar) -ForegroundColor Green
      $resolved = $true
      break
    } else {
      # * Restore the candidate.
      Write-Host ("    {0} did not fix the crash. Restoring." -f $candJar) -ForegroundColor Gray
      Move-Item -LiteralPath $tempDest -Destination $gamePath -Force
      if ($null -ne $storageTemp -and (Test-Path -LiteralPath $storageTemp)) {
        Move-Item -LiteralPath $storageTemp -Destination $storagePath -Force
      }
    }
  }

  if ($resolved) { break }
}

# * Clean up empty temp dirs.
$tempRoot = Join-Path -Path $GameModsDir -ChildPath ("{0}\temp" -f $GameLegacyFolderName)
if (Test-Path -LiteralPath $tempRoot) {
  Get-ChildItem -LiteralPath $tempRoot -Directory -Filter "mixin-*" -ErrorAction SilentlyContinue |
    Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -ErrorAction SilentlyContinue).Count -eq 0 } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

# ────────────────────────────────────────────────────────────────────────────
# * Summary.
# ────────────────────────────────────────────────────────────────────────────

if ($culpritJarNames.Count -gt 0) {
  Write-Host ("Mixin analysis resolved {0} culprit(s): {1}" -f $culpritJarNames.Count, ($culpritJarNames -join ", ")) -ForegroundColor Green
} else {
  Write-Host "Mixin analysis could not resolve the crash by targeted removal." -ForegroundColor Yellow
}

if ($mixinConflicts.Count -gt 0) {
  Write-Host ("Mixin analysis detected {0} mod conflict(s):" -f $mixinConflicts.Count) -ForegroundColor Cyan
  foreach ($conflict in $mixinConflicts) {
    $srcLabel = if (-not [string]::IsNullOrWhiteSpace($conflict.SourceJar)) { $conflict.SourceJar } else { $conflict.SourceModId }
    $tgtLabel = if (-not [string]::IsNullOrWhiteSpace($conflict.TargetModId)) { $conflict.TargetModId } else { $conflict.TargetClass }
    if ($conflict.ErrorKind -eq "apply_failed") {
      $mixLabel = if (-not [string]::IsNullOrWhiteSpace($conflict.MixinJson)) { $conflict.MixinJson } else { "<unknown mixin config>" }
      Write-Host ("  {0} (mod: {1}) failed to apply {2} to {3}" -f $srcLabel, $conflict.SourceModId, $mixLabel, $tgtLabel) -ForegroundColor Gray
    } else {
      Write-Host ("  {0} (mod: {1}) targets missing class in {2}" -f $srcLabel, $conflict.SourceModId, $tgtLabel) -ForegroundColor Gray
    }
  }
}

if ($EmitResultObject) {
  Write-Output ([pscustomobject]@{
      Type             = "MixinAnalysisResult"
      CulpritJarNames  = @($culpritJarNames)
      CulpritMoves     = @($culpritMoves.ToArray())
      MixinConflicts   = @($mixinConflicts.ToArray())
      Resolved         = $resolved
      GameModsDir      = $GameModsDir
      StorageModsDir   = if ($useStorage) { $StorageModsDir } else { "" }
      Minecraft        = $mcVersionForLegacy
    })
}

exit $(if ($resolved) { 0 } else { 1 })
