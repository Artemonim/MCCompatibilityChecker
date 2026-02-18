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
  [string]$GameLegacyFolderName = "",

  [Parameter(Mandatory = $false)]
  [string]$StorageModsDir = "",

  [Parameter(Mandatory = $false)]
  [string]$StorageLegacyFolderName = "",

  [Parameter(Mandatory = $false)]
  [switch]$KeepCulpritInGameLegacy,

  [Parameter(Mandatory = $false)]
  [string]$LogPath = "",

  [Parameter(Mandatory = $false)]
  [int]$LogMaxAgeMinutes = 30,

  [Parameter(Mandatory = $false)]
  [datetime]$LogSinceTimestamp = [datetime]::MinValue,

  [Parameter(Mandatory = $false)]
  [int]$LogSinceSkewSeconds = 120,

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
  [string[]]$PlayButtonNames = @("Launch", "Play", "Start"),

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
  [string[]]$CrashWindowTitlePatterns = @("Something broke"),

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

  # * If true, uses MCCC.json in GameModsDir to prioritize unknown candidates.
  [Parameter(Mandatory = $false)]
  [bool]$UseHashCache = $true,

  # * Cache file name stored in GameModsDir.
  [Parameter(Mandatory = $false)]
  [string]$HashCacheFileName = "MCCC.json",

  # * File hash retry settings (handles transient locks).
  [Parameter(Mandatory = $false)]
  [int]$HashCacheHashRetryCount = 3,

  [Parameter(Mandatory = $false)]
  [int]$HashCacheHashRetryDelayMs = 200,

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

$sharedBootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Bootstrap.ps1"
if (-not (Test-Path -LiteralPath $sharedBootstrapPath)) {
  throw ("Shared bootstrap helpers not found: {0}" -f $sharedBootstrapPath)
}
. $sharedBootstrapPath
. Initialize-McccRuntimeBootstrap `
  -StartDir $PSScriptRoot `
  -LoadConfig `
  -InitializeLocalization `
  -EnableConsoleLocalization `
  -ConfigNotFoundMessage "Shared config helpers not found: {0}" `
  -LocalizationNotFoundMessage "Shared localization helpers not found: {0}" | Out-Null
if (-not $PSBoundParameters.ContainsKey("CrashWindowTitlePatterns")) {
  $CrashWindowTitlePatterns = Get-McccLocaleCrashWindowTitlePatternSet -StartDir $PSScriptRoot -FallbackPatterns $CrashWindowTitlePatterns
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# * Launch wait scaling config.
$launchWaitBaseSeconds = 20
$launchWaitPerModSeconds = 0.1

$useDynamicOutcomeTimeout = -not $PSBoundParameters.ContainsKey("OutcomeTimeoutSeconds")
$useDynamicSuccessConfirm = -not $PSBoundParameters.ContainsKey("SuccessConfirmSeconds")

# ────────────────────────────────────────────────────────────────────────────
# * Load shared modules.
# ────────────────────────────────────────────────────────────────────────────

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
$sharedLegacyPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Legacy.ps1"
if (-not (Test-Path -LiteralPath $sharedLegacyPath)) { throw ("Shared legacy helpers not found: {0}" -f $sharedLegacyPath) }
. $sharedLegacyPath

$sharedFileOpsPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-FileOps.ps1"
if (-not (Test-Path -LiteralPath $sharedFileOpsPath)) { throw ("Shared file operation helpers not found: {0}" -f $sharedFileOpsPath) }
. $sharedFileOpsPath

$sharedStageResultPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-StageResult.ps1"
if (-not (Test-Path -LiteralPath $sharedStageResultPath)) { throw ("Shared stage result helpers not found: {0}" -f $sharedStageResultPath) }
. $sharedStageResultPath
$sharedHashCachePath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-HashCache.ps1"
if (-not (Test-Path -LiteralPath $sharedHashCachePath)) { throw ("Shared hash cache helpers not found: {0}" -f $sharedHashCachePath) }
. $sharedHashCachePath
$runtimeConfig = Initialize-McccRuntimeConfig `
  -StartDir $PSScriptRoot `
  -BoundParameters $PSBoundParameters `
  -GameModsDir $GameModsDir `
  -StorageModsDir $StorageModsDir `
  -LogPath $LogPath `
  -LauncherExePath $LauncherExePath `
  -AlwaysDefaultGameModsDir $true `
  -DefaultStorageToGame $false `
  -TreatEmptyAsUnboundKeys @("GameModsDir", "StorageModsDir", "LogPath", "LauncherExePath")
$GameModsDir = $runtimeConfig.Paths.GameModsDir
$StorageModsDir = $runtimeConfig.Paths.StorageModsDir
$LogPath = $runtimeConfig.Paths.LogPath
$LauncherExePath = $runtimeConfig.Paths.LauncherExePath
$useStorage = $runtimeConfig.Paths.UseStorage

$resolvedLegacyFolders = Resolve-McccLegacyFolderNames `
  -GameLegacyFolderName $GameLegacyFolderName `
  -StorageLegacyFolderName $StorageLegacyFolderName
$GameLegacyFolderName = [string]$resolvedLegacyFolders.GameLegacyFolderName
$StorageLegacyFolderName = [string]$resolvedLegacyFolders.StorageLegacyFolderName

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
  $jarFiles = Get-McccJarFiles -RootPaths @($ModsDir) -SortBy "LastWriteTime" -Descending $true -EnumerationErrorAction "SilentlyContinue"

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

$mcVersionForLegacy = "unknown"
$logSnapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $LogSinceTimestamp -SinceTimestampSkewSeconds $LogSinceSkewSeconds
if ($null -eq $logSnapshot -or $logSnapshot.Lines.Count -eq 0) {
  Write-Host "Mixin analysis: no crash log available." -ForegroundColor Gray
  if ($EmitResultObject) {
    $stageResultParams = @{
      Stage = "MixinAnalysis"
      Type = "MixinAnalysisResult"
      GameModsDir = $GameModsDir
      StorageModsDir = if ($useStorage) { $StorageModsDir } else { "" }
      Minecraft = $mcVersionForLegacy
      ExitCode = 0
      CulpritJarNames = @()
      CulpritMoves = @()
      ExtraFields = @{
        MixinConflicts = @()
        Resolved       = $false
      }
    }
    Write-Output (New-StageResult @stageResultParams)
  }
  exit 0
}

$mixinApplyErrors = Get-MixinApplyErrorsFromLog -Lines $logSnapshot.Lines
$mixinTargetErrors = Get-MixinErrorsFromLog -Lines $logSnapshot.Lines
if ($mixinApplyErrors.Count -eq 0 -and $mixinTargetErrors.Count -eq 0) {
  Write-Host "Mixin analysis: no supported Mixin errors found in crash log." -ForegroundColor Gray
  if ($EmitResultObject) {
    $stageResultParams = @{
      Stage = "MixinAnalysis"
      Type = "MixinAnalysisResult"
      GameModsDir = $GameModsDir
      StorageModsDir = if ($useStorage) { $StorageModsDir } else { "" }
      Minecraft = $mcVersionForLegacy
      ExitCode = 0
      CulpritJarNames = @()
      CulpritMoves = @()
      ExtraFields = @{
        MixinConflicts = @()
        Resolved       = $false
      }
    }
    Write-Output (New-StageResult @stageResultParams)
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

# * Build jar priority metadata (tier/dependents) for final report annotations.
$mixinPriorityByJarName = @{}
$mixinTier2MaxDependents = 3
$mixinTier3MaxDependents = 10
if ($null -ne $dependencyMap) {
  $depCounts = Get-DependentModCountsFromDependencyMap -DependencyMap $dependencyMap -CountMode "RequiredOnly"
  foreach ($jarKey in $depCounts.Keys) {
    $depCount = [int]$depCounts[$jarKey].DependentCount
    $known = [bool]$depCounts[$jarKey].Known
    $tier = 4
    if ($known) {
      if ($depCount -le 0) {
        $tier = 1
      } elseif ($depCount -le $mixinTier2MaxDependents) {
        $tier = 2
      } elseif ($depCount -le $mixinTier3MaxDependents) {
        $tier = 3
      }
    }
    $mixinPriorityByJarName[$jarKey] = [pscustomobject]@{
      Tier = [int]$tier
      DependentCount = [int]$depCount
      Known = [bool]$known
    }
  }
}

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
    $stageResultParams = @{
      Stage = "MixinAnalysis"
      Type = "MixinAnalysisResult"
      GameModsDir = $GameModsDir
      StorageModsDir = if ($useStorage) { $StorageModsDir } else { "" }
      Minecraft = $mcVersionForLegacy
      ExitCode = 0
      CulpritJarNames = @()
      CulpritMoves = @()
      ExtraFields = @{
        MixinConflicts = @()
        Resolved       = $false
      }
    }
    Write-Output (New-StageResult @stageResultParams)
  }
  exit 0
}

# ────────────────────────────────────────────────────────────────────────────
# * Resolve candidates and run staged Mixin strategy.
# ────────────────────────────────────────────────────────────────────────────

$mcVersionForLegacy = Get-MinecraftVersionFromLog -Lines $logSnapshot.Lines
if ([string]::IsNullOrWhiteSpace($mcVersionForLegacy)) { $mcVersionForLegacy = "unknown" }

$culpritJarNames = New-Object System.Collections.Generic.List[string]
$culpritMoves = New-Object System.Collections.Generic.List[pscustomobject]
$mixinConflicts = New-Object System.Collections.Generic.List[pscustomobject]
$resolved = $false

$script:mixinHashCacheEnabled = $false
$script:mixinHashCache = $null
$script:mixinHashKnownGoodByJar = @{}
if ((-not $DryRun) -and $UseHashCache) {
  $mixinCachePath = Get-McccHashCachePath -GameModsDir $GameModsDir -FileName $HashCacheFileName
  $script:mixinHashCache = Read-McccHashCache -Path $mixinCachePath
  if ($null -ne $script:mixinHashCache -and $script:mixinHashCache.ContainsKey("passed") -and ($script:mixinHashCache["passed"] -is [hashtable])) {
    $script:mixinHashCacheEnabled = ($script:mixinHashCache["passed"].Count -gt 0)
  }
}

function Test-MixinCandidateKnownGoodByHash {
  [OutputType([bool])]
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarName
  )

  if (-not $script:mixinHashCacheEnabled) { return $false }
  if ([string]::IsNullOrWhiteSpace($JarName)) { return $false }

  $key = $JarName.Trim().ToLowerInvariant()
  if ($script:mixinHashKnownGoodByJar.ContainsKey($key)) {
    return [bool]$script:mixinHashKnownGoodByJar[$key]
  }

  $jarPath = Join-Path -Path $GameModsDir -ChildPath $JarName
  if (-not (Test-Path -LiteralPath $jarPath)) {
    $script:mixinHashKnownGoodByJar[$key] = $false
    return $false
  }

  $hash = Get-Sha256LowerHex -Path $jarPath -Retries $HashCacheHashRetryCount -DelayMs $HashCacheHashRetryDelayMs
  if ([string]::IsNullOrWhiteSpace($hash)) {
    $script:mixinHashKnownGoodByJar[$key] = $false
    return $false
  }

  $isKnownGood = Test-McccHashPassed -Cache $script:mixinHashCache -Sha256LowerHex $hash
  $script:mixinHashKnownGoodByJar[$key] = [bool]$isKnownGood
  return [bool]$isKnownGood
}

function Get-MixinProbeConfirmDuration {
  [OutputType([int])]
  param()

  $effectiveConfirmSeconds = $SuccessConfirmSeconds
  if ($useDynamicOutcomeTimeout -or $useDynamicSuccessConfirm) {
    $activeModCount = Get-ActiveModCount -ModsDir $GameModsDir
    $scaledLaunchSeconds = Get-ScaledLaunchWaitTime -ActiveModCount $activeModCount `
      -PerModSeconds $launchWaitPerModSeconds `
      -BaseSeconds $launchWaitBaseSeconds
    if ($useDynamicOutcomeTimeout) { Set-Variable -Name "OutcomeTimeoutSeconds" -Scope Script -Value $scaledLaunchSeconds }
    if ($useDynamicSuccessConfirm) { $effectiveConfirmSeconds = $scaledLaunchSeconds }
  }
  return [int]$effectiveConfirmSeconds
}

function Invoke-MixinLaunchProbe {
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory = $false)]
    [string]$ProbeLabel = ""
  )

  $effectiveConfirmSeconds = Get-MixinProbeConfirmDuration
  $launchStart = Get-Date
  $outcomeType = "Unknown"
  $isSuccess = $false

  try {
    # * Close any stray crash dialogs before each probe.
    $strayCrash = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
    if ($null -ne $strayCrash) {
      Write-Host ("    Closing stray crash dialog before probe: {0}" -f $strayCrash.Title) -ForegroundColor Gray
      Invoke-WindowClose -Handle $strayCrash.Handle
      Start-Sleep -Seconds 2
    }

    $outcome = Invoke-ConfiguredLaunchAttempt
    $outcomeType = [string]$outcome.Type
    if ([string]::IsNullOrWhiteSpace($ProbeLabel)) {
      Write-Host ("    Outcome: {0}" -f $outcomeType) -ForegroundColor Gray
    } else {
      Write-Host ("    Outcome ({0}): {1}" -f $ProbeLabel, $outcomeType) -ForegroundColor Gray
    }

    if ($outcome.Type -eq "Timeout") {
      Write-Host ("    Confirming stability ({0}s)..." -f $effectiveConfirmSeconds) -ForegroundColor Gray
      Start-Sleep -Seconds $effectiveConfirmSeconds
      $crashNow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
      if ($null -eq $crashNow) {
        $isSuccess = $true
      } else {
        Invoke-WindowClose -Handle $crashNow.Handle
      }
      [void](Stop-ConfiguredGameProcess -StartedAfter $launchStart)
    }

    if ($outcome.Type -eq "CrashDialog" -and $null -ne $outcome.Window) {
      Invoke-WindowClose -Handle $outcome.Window.Handle
    }
    if ($outcome.Type -eq "FabricDialog" -and $null -ne $outcome.Window) {
      Invoke-WindowClose -Handle $outcome.Window.Handle
    }

    Start-Sleep -Seconds 2
    $postCrash = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
    if ($null -ne $postCrash) {
      Invoke-WindowClose -Handle $postCrash.Handle
    }
  } finally {
    [void](Stop-ConfiguredGameProcess -StartedAfter $launchStart)
    [void](Wait-ConfiguredGameExit -StartedAfter $launchStart -WarningContext "Mixin analysis cleanup")
  }

  return [pscustomobject]@{
    IsSuccess = [bool]$isSuccess
    OutcomeType = $outcomeType
  }
}

$candidateByJar = @{}
$candidateOrder = 0

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

  # * Try candidates with priority: unknown-by-hash first, then known-good-by-hash.
  $candidateObjects = New-Object System.Collections.Generic.List[object]
  if ($null -ne $sourceJar) {
    $candidateObjects.Add([pscustomobject]@{
        JarName = $sourceJar
        BaseOrder = 0
      })
  }
  $allowTargetCandidate = ($null -ne $targetJar -and $targetJar -ne $sourceJar)
  if ($allowTargetCandidate -and $mxErr.ErrorKind -eq "apply_failed") {
    if ($isMinecraftTargetClass -or $targetModId -in @("minecraft", "java", "fabricloader")) {
      $allowTargetCandidate = $false
    }
  }
  if ($allowTargetCandidate) {
    $candidateObjects.Add([pscustomobject]@{
        JarName = $targetJar
        BaseOrder = 1
      })
  }

  $candidates = @(
    $candidateObjects |
      Sort-Object -Property `
        @{ Expression = { if (Test-MixinCandidateKnownGoodByHash -JarName ([string]$_.JarName) ) { 1 } else { 0 } }; Ascending = $true }, `
        @{ Expression = { [int]$_.BaseOrder }; Ascending = $true } |
      ForEach-Object { [string]$_.JarName }
  )

  foreach ($candJar in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candJar)) { continue }
    $candidateKey = $candJar.ToLowerInvariant()
    if ($candidateByJar.ContainsKey($candidateKey)) { continue }
    $candidateByJar[$candidateKey] = [pscustomobject]@{
      JarName = $candJar
      JarKey = $candidateKey
      Order = $candidateOrder
      CrashEvidenceKey = [string]$mxErr.ErrorLine
    }
    $candidateOrder++
  }
}

$orderedCandidates = @(
  $candidateByJar.Values |
    Sort-Object -Property @{ Expression = { [int]$_.Order }; Ascending = $true }
)

if ($orderedCandidates.Count -eq 0) {
  Write-Host "Mixin analysis: no candidate jars resolved from Mixin errors." -ForegroundColor Yellow
} elseif ($DryRun) {
  Write-Host ("DRYRUN: staged Mixin analysis would quarantine {0} candidate mod(s), run one batch probe, then layer candidates back." -f $orderedCandidates.Count) -ForegroundColor Gray
} else {
  $batchTempRoot = Get-McccLegacyTempRootPath -ModsDir $GameModsDir -GameLegacyFolderName $GameLegacyFolderName
  $batchTempDir = Join-Path -Path $batchTempRoot -ChildPath ("mixin-batch-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
  if (-not (Test-Path -LiteralPath $batchTempDir)) {
    New-Item -ItemType Directory -Path $batchTempDir -Force | Out-Null
  }

  $candidateStates = New-Object System.Collections.Generic.List[object]
  try {
    foreach ($entry in $orderedCandidates) {
      $jarName = [string]$entry.JarName
      if ([string]::IsNullOrWhiteSpace($jarName)) { continue }

      $gamePath = Join-Path -Path $GameModsDir -ChildPath $jarName
      $tempGamePath = Join-Path -Path $batchTempDir -ChildPath $jarName
      $storagePath = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $jarName } else { "" }
      $tempStoragePath = if ($useStorage) { Join-Path -Path $batchTempDir -ChildPath ("storage-{0}" -f $jarName) } else { "" }

      $state = [pscustomobject]@{
        JarName = $jarName
        JarKey = [string]$entry.JarKey
        Order = [int]$entry.Order
        CrashEvidenceKey = [string]$entry.CrashEvidenceKey
        GamePath = $gamePath
        TempGamePath = $tempGamePath
        StoragePath = $storagePath
        TempStoragePath = $tempStoragePath
        WasQuarantined = $false
        HasStorageBackup = $false
        IsKnownGood = $false
        IsCulprit = $false
      }
      $candidateStates.Add($state) | Out-Null

      if (-not (Test-Path -LiteralPath $gamePath)) {
        Write-Host ("    Skipping {0}: not found in game mods." -f $jarName) -ForegroundColor Gray
        continue
      }

      $quarantineGameResult = Move-McccItem -LiteralPath $gamePath -DestinationPath $tempGamePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
      if (-not $quarantineGameResult.Performed) {
        throw ("Failed to quarantine candidate mod from game: {0}" -f $jarName)
      }
      $state.WasQuarantined = $true

      if ($useStorage -and -not [string]::IsNullOrWhiteSpace($storagePath) -and (Test-Path -LiteralPath $storagePath)) {
        $quarantineStorageResult = Move-McccItem -LiteralPath $storagePath -DestinationPath $tempStoragePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        if (-not $quarantineStorageResult.Performed) {
          throw ("Failed to quarantine candidate mod from storage: {0}" -f $jarName)
        }
        $state.HasStorageBackup = [bool]$quarantineStorageResult.Performed
      }
    }

    $activeCandidates = @($candidateStates | Where-Object { [bool]$_.WasQuarantined })
    if ($activeCandidates.Count -eq 0) {
      Write-Host "Mixin analysis: no candidate jars are available for staged probing." -ForegroundColor Yellow
    } else {
      Write-Host ("Batch probe: disabled all {0} resolved Mixin candidate mod(s)." -f $activeCandidates.Count) -ForegroundColor Cyan
      $batchProbe = Invoke-MixinLaunchProbe -ProbeLabel "batch-without-mixin-candidates"

      if (-not [bool]$batchProbe.IsSuccess) {
        Write-Host "Batch probe failed after removing all Mixin candidates. Handing off to next stage." -ForegroundColor Yellow
      } else {
        Write-Host "Batch probe succeeded. Crash is inside resolved Mixin candidates; starting layered add-back." -ForegroundColor Green
        $layerOrderedCandidates = @(
          $activeCandidates |
            Sort-Object -Property `
              @{ Expression = { if (Test-MixinCandidateKnownGoodByHash -JarName ([string]$_.JarName)) { 1 } else { 0 } }; Ascending = $true }, `
              @{ Expression = { [int]$_.Order }; Ascending = $true }
        )

        foreach ($state in $layerOrderedCandidates) {
          if ($state.IsCulprit) { continue }
          if (Test-Path -LiteralPath $state.TempGamePath) {
            $restoreGameResult = Move-McccItem -LiteralPath $state.TempGamePath -DestinationPath $state.GamePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
            if (-not $restoreGameResult.Performed) {
              throw ("Failed to restore candidate into game before probe: {0}" -f $state.JarName)
            }
          }
          if ([bool]$state.HasStorageBackup -and (Test-Path -LiteralPath $state.TempStoragePath) -and -not [string]::IsNullOrWhiteSpace([string]$state.StoragePath)) {
            $restoreStorageResult = Move-McccItem -LiteralPath $state.TempStoragePath -DestinationPath $state.StoragePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
            if (-not $restoreStorageResult.Performed) {
              throw ("Failed to restore candidate into storage before probe: {0}" -f $state.JarName)
            }
          }

          Write-Host ("    Layering probe: add back {0}" -f $state.JarName) -ForegroundColor Cyan
          $probe = Invoke-MixinLaunchProbe -ProbeLabel ("add-back {0}" -f $state.JarName)
          if ([bool]$probe.IsSuccess) {
            Write-Host ("    {0} does not reintroduce the crash." -f $state.JarName) -ForegroundColor Gray
            $state.IsKnownGood = $true
            continue
          }

          Write-Host ("    {0} reintroduces the crash. Moving to Legacy." -f $state.JarName) -ForegroundColor Yellow

          $storageSourcePath = if ($useStorage) {
            Get-FirstExistingPath -Candidates @($state.StoragePath, $state.TempStoragePath)
          } else {
            ""
          }
          $gameSourcePath = Get-FirstExistingPath -Candidates @($state.GamePath, $state.TempGamePath)
          if ([string]::IsNullOrWhiteSpace($gameSourcePath)) {
            Write-Host ("Warning: failed to locate candidate for legacy move: {0}" -f $state.JarName) -ForegroundColor Yellow
            continue
          }

          $moveResult = Move-CulpritToLegacyAndAppendLog `
            -JarName $state.JarName `
            -MinecraftVersion $mcVersionForLegacy `
            -GameModsDir $GameModsDir `
            -StorageModsDir $StorageModsDir `
            -GameLegacyFolderName $GameLegacyFolderName `
            -StorageLegacyFolderName $StorageLegacyFolderName `
            -KeepCulpritInGameLegacy ([bool]$KeepCulpritInGameLegacy) `
            -StorageSourcePath $storageSourcePath `
            -GameSourcePath $gameSourcePath `
            -StorageTransferMode "Copy" `
            -GameTransferMode "Move"
          $culpritStorageLegacy = $moveResult.StorageLegacyPath
          $culpritGameLegacy = $moveResult.GameLegacyPath

          $priorityTier = 4
          $priorityDependentCount = -1
          $priorityKnown = $false
          if ($mixinPriorityByJarName.ContainsKey($state.JarKey)) {
            $priorityMeta = $mixinPriorityByJarName[$state.JarKey]
            if ($null -ne $priorityMeta) {
              $priorityTier = [int]$priorityMeta.Tier
              $priorityDependentCount = [int]$priorityMeta.DependentCount
              $priorityKnown = [bool]$priorityMeta.Known
            }
          }
          $priorityDecision = if ($priorityKnown) {
            "dependency-priority metadata: tier={0}, dependents={1}" -f $priorityTier, $priorityDependentCount
          } else {
            "dependency-priority metadata unavailable for this jar"
          }

          $culpritJarNames.Add($state.JarName)
          $culpritMoves.Add([pscustomobject]@{
              JarName            = $state.JarName
              GameModsDir        = $GameModsDir
              StorageModsDir     = if ($useStorage) { $StorageModsDir } else { "" }
              StorageLegacyPath  = $culpritStorageLegacy
              GameLegacyPath     = $culpritGameLegacy
              Minecraft          = $mcVersionForLegacy
              KeepCulpritInGameLegacy = [bool]$KeepCulpritInGameLegacy
              CrashEvidenceKey   = $state.CrashEvidenceKey
              DependencyTier     = [int]$priorityTier
              DependentModCount  = [int]$priorityDependentCount
              DependentModCountKnown = [bool]$priorityKnown
              PriorityDecision   = $priorityDecision
              Stage              = "mixin-analysis"
            })
          $state.IsCulprit = $true
          $resolved = $true
        }
      }
    }
  } finally {
    foreach ($state in @($candidateStates | Where-Object { [bool]$_.WasQuarantined })) {
      if ([bool]$state.IsCulprit) { continue }
      if (Test-Path -LiteralPath $state.TempGamePath) {
        try {
          $null = Move-McccItem -LiteralPath $state.TempGamePath -DestinationPath $state.GamePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        } catch { }
      }
      if ([bool]$state.HasStorageBackup -and (Test-Path -LiteralPath $state.TempStoragePath) -and -not [string]::IsNullOrWhiteSpace([string]$state.StoragePath)) {
        try {
          $null = Move-McccItem -LiteralPath $state.TempStoragePath -DestinationPath $state.StoragePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        } catch { }
      }
    }
  }
}

# * Clean up empty temp dirs.
$tempRoot = Get-McccLegacyTempRootPath -ModsDir $GameModsDir -GameLegacyFolderName $GameLegacyFolderName
if (Test-Path -LiteralPath $tempRoot) {
  Get-ChildItem -LiteralPath $tempRoot -Directory -Filter "mixin-*" -ErrorAction SilentlyContinue |
    Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -ErrorAction SilentlyContinue).Count -eq 0 } |
    ForEach-Object {
      try {
        $null = Remove-McccItem -LiteralPath $_.FullName -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
      } catch { }
    }
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

$exitCode = if ($resolved) { 0 } else { 1 }

if ($EmitResultObject) {
  $stageResultParams = @{
    Stage = "MixinAnalysis"
    Type = "MixinAnalysisResult"
    GameModsDir = $GameModsDir
    StorageModsDir = if ($useStorage) { $StorageModsDir } else { "" }
    Minecraft = $mcVersionForLegacy
    ExitCode = $exitCode
    CulpritJarNames = @($culpritJarNames)
    CulpritMoves = @($culpritMoves.ToArray())
    ExtraFields = @{
      MixinConflicts = @($mixinConflicts.ToArray())
      Resolved       = $resolved
    }
  }
  Write-Output (New-StageResult @stageResultParams)
}

if ($exitCode -eq 0 -and (-not $DryRun)) {
  $finalCrashWindow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
  if ($null -ne $finalCrashWindow) {
    Write-Host ("Closing remaining crash window: {0}" -f $finalCrashWindow.Title) -ForegroundColor Gray
    [void](Close-OutcomeWindowWithExtraDialog -Outcome ([pscustomobject]@{ Type = "CrashDialog"; Window = $finalCrashWindow }) `
      -DelaySeconds $CrashCloseDelaySeconds `
      -OffsetX $CrashCloseClickOffsetX `
      -OffsetY $CrashCloseClickOffsetY `
      -CloseExtraFabricDialogs $true)
  }
}

exit $exitCode
