<#
.SYNOPSIS
Layering isolation: starts with core libraries only, then adds mods back in exponential batches.

.DESCRIPTION
Fallback strategy when the standard subtractive isolation cannot identify a culprit.
Instead of removing mods one-by-one, this script:
  1. Quarantines all non-core (non-tier-4) mods.
  2. Verifies the game launches with core libraries only.
  3. Adds mods back tier by tier (tier-3, tier-2, tier-1) in exponentially growing batches.
  4. When a batch causes a crash:
     a. Tries the basic algorithm (reads crash log to identify the mod).
     b. If the log does not identify the culprit, runs binary isolation within the batch.
  5. Culprit mods are moved to Legacy; layering continues with the remaining mods.

This script dot-sources the same shared helpers as Isolate-Incompatible-Mod.ps1 and reuses
the quarantine, launch, log-parsing, and binary isolation infrastructure.

.PARAMETER GameModsDir
Active mods folder used by the launcher/game.

.PARAMETER GameLegacyFolderName
Folder name inside GameModsDir used to store quarantined mods (uses Legacy\temp).

.PARAMETER StorageModsDir
Optional storage mods folder. If empty, storage operations are skipped.

.PARAMETER StorageLegacyFolderName
Folder name inside StorageModsDir used to store quarantined mods (uses Legacy\temp).

.PARAMETER KeepCulpritInGameLegacy
If set, keeps the culprit jar in game legacy folder too.

.PARAMETER LogPath
Optional log path to use as primary log.

.PARAMETER LogMaxAgeMinutes
Maximum age (minutes) for additional game logs.

.PARAMETER SkipGameLogs
If set, skips scanning game logs when LogPath is empty.

.PARAMETER LogReadRetryCount
Retry count when reading a log that may still be writing.

.PARAMETER LogReadRetryDelayMs
Delay between log read retries.

.PARAMETER LogPostRunDelaySeconds
Delay after a launch attempt to let logs flush.

.PARAMETER WaitForGameExitSeconds
Maximum seconds to wait for game JVM/processes to exit after a crash.

.PARAMETER GameProcessNames
Process names to wait for (without .exe).

.PARAMETER GameExitPollSeconds
Polling interval while waiting for game processes to exit.

.PARAMETER SuccessConfirmSeconds
Seconds to wait after a successful launch to confirm no crash before killing the game.

.PARAMETER ErrorSignatureLineLimit
Number of error lines to include in the signature.

.PARAMETER IncludeWarnMixinsAsIncompatible
If set, also matches WARN mixin lines in the signature.

.PARAMETER IgnoreModListForSignatureChange
If true, signature change detection prefers evidence lines when present.

.PARAMETER LauncherExePath
Optional path to Legacy Launcher executable.

.PARAMETER LauncherArguments
Additional launcher CLI arguments.

.PARAMETER UseAutoLaunch
If set, appends --launch to enable auto-start.

.PARAMETER LauncherWindowTitlePattern
Partial title of the launcher main window.

.PARAMETER PlayButtonNames
Button names to start the game.

.PARAMETER PlayClickOffsetX
Optional click offset (pixels) relative to the top-left of the launcher window.

.PARAMETER PlayClickOffsetY
Optional click offset (pixels) relative to the top-left of the launcher window.

.PARAMETER PlayClickDelayMs
Delay (ms) after focusing the launcher and before clicking Play.

.PARAMETER LaunchStartTimeoutSeconds
Seconds to wait after triggering Play to detect game start.

.PARAMETER PlayClickMaxAttempts
How many times to try triggering Play when no game start is detected.

.PARAMETER RequireGameStartForTimeout
If true, Timeout outcome is only treated as success when game start is detected.

.PARAMETER BinaryLinearThreshold
Falls back to linear once the candidate set is at or below this size during binary refinement.

.PARAMETER UseEnterFallback
If true, sends ENTER when play element is not found.

.PARAMETER EnableBroadUiSearch
If true, enables broad UI Automation fallback search.

.PARAMETER CrashWindowTitlePatterns
Crash dialog title fragments.

.PARAMETER FabricWindowTitlePatterns
Fabric or dependency dialog title fragments.

.PARAMETER CrashCloseClickOffsetX
Optional click offset for closing crash dialog.

.PARAMETER CrashCloseClickOffsetY
Optional click offset for closing crash dialog.

.PARAMETER CrashCloseDelaySeconds
Delay before closing crash dialog.

.PARAMETER LauncherWindowTimeoutSeconds
Wait time to find launcher window after start.

.PARAMETER OutcomeTimeoutSeconds
Time window to detect outcomes after clicking Play.

.PARAMETER PollIntervalSeconds
Polling interval.

.PARAMETER DependencyAwareOrderingCountMode
Dependency graph counting mode.

.PARAMETER DependencyAwareTier2MaxDependents
Tier 2 threshold.

.PARAMETER DependencyAwareTier3MaxDependents
Tier 3 threshold.

.PARAMETER DependencyAwareTreatUnknownAsCore
If true, jars with unknown metadata are treated as core libraries (tier 4).

.PARAMETER DependencyAwareQuickIsolateMaxTier
Max tier allowed for quick-isolate.

.PARAMETER DependencyMapSource
Dependency map source: Tool, File, or Internal.

.PARAMETER DependencyMapJsonPath
Dependency map JSON path when DependencyMapSource=File.

.PARAMETER DependencyMapToolPath
Path to Analyze-JarDependencyMap.ps1 when DependencyMapSource=Tool.

.PARAMETER DependencyMapOutDir
Output directory for dependency map tool reports.

.PARAMETER ExcludeJarNames
Array of jar file names to skip.

.PARAMETER NoCache
If set, disables the session launch-configuration cache and always re-runs launch checks.

.PARAMETER MoveRetryCount
How many times to retry moving a jar if locked.

.PARAMETER MoveRetryDelayMs
Delay between move retries.

.PARAMETER EmitResultObject
If set, emits a single structured object to the pipeline with run details.

.PARAMETER ForceRestore
If set, overwrites existing jars when restoring.

.PARAMETER KeepMovedModsOnFailure
If set, does not restore moved mods on unexpected errors.

.PARAMETER DryRun
If set, only prints the planned order and exits.

.PARAMETER Help
Show detailed help and exit.

.EXAMPLE
.\Layer-Mods.ps1 -SkipBaselineRun -PlayClickOffsetX 210 -PlayClickOffsetY 440
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
  [switch]$SkipGameLogs,

  [Parameter(Mandatory = $false)]
  [int]$LogReadRetryCount = 5,

  [Parameter(Mandatory = $false)]
  [int]$LogReadRetryDelayMs = 500,

  [Parameter(Mandatory = $false)]
  [int]$LogPostRunDelaySeconds = 3,

  [Parameter(Mandatory = $false)]
  [int]$WaitForGameExitSeconds = 30,

  [Parameter(Mandatory = $false)]
  [string[]]$GameProcessNames = @("javaw", "java", "Minecraft"),

  [Parameter(Mandatory = $false)]
  [int]$GameExitPollSeconds = 2,

  # * Seconds to wait after Timeout outcome to confirm the launch is stable.
  [Parameter(Mandatory = $false)]
  [int]$SuccessConfirmSeconds = 20,

  # * Enables extended stability confirmation scaling (+0.3s per active mod).
  [Parameter(Mandatory = $false)]
  [Alias("ThoroughStabilityCheck")]
  [switch]$LongLaunchTimeout,

  [Parameter(Mandatory = $false)]
  [int]$ErrorSignatureLineLimit = 2,

  [Parameter(Mandatory = $false)]
  [switch]$IncludeWarnMixinsAsIncompatible,

  [Parameter(Mandatory = $false)]
  [bool]$IgnoreModListForSignatureChange = $true,

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
  [int]$BinaryLinearThreshold = 1,

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
  [ValidateSet("RequiredOnly", "All")]
  [string]$DependencyAwareOrderingCountMode = "RequiredOnly",

  [Parameter(Mandatory = $false)]
  [int]$DependencyAwareTier2MaxDependents = 3,

  [Parameter(Mandatory = $false)]
  [int]$DependencyAwareTier3MaxDependents = 10,

  [Parameter(Mandatory = $false)]
  [bool]$DependencyAwareTreatUnknownAsCore = $true,

  [Parameter(Mandatory = $false)]
  [int]$DependencyAwareQuickIsolateMaxTier = 3,

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
  [string[]]$ExcludeJarNames = @(),

  # * If true, uses MCCC.json in GameModsDir to skip previously passed mods (by SHA256).
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

  # * If set, disables the session launch-config cache and forces repeated checks.
  [Parameter(Mandatory = $false)]
  [switch]$NoCache,

  [Parameter(Mandatory = $false)]
  [switch]$EmitResultObject,

  [Parameter(Mandatory = $false)]
  [int]$MoveRetryCount = 15,

  [Parameter(Mandatory = $false)]
  [int]$MoveRetryDelayMs = 1000,

  [Parameter(Mandatory = $false)]
  [switch]$ForceRestore,

  [Parameter(Mandatory = $false)]
  [switch]$KeepMovedModsOnFailure,

  [Parameter(Mandatory = $false)]
  [switch]$DryRun,

  [Parameter(Mandatory = $false)]
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# * Launch wait scaling config.
$launchWaitBaseSeconds = 20
$launchWaitPerModSeconds = 0.1
$launchWaitPerModSecondsLong = 0.3

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

if ($Help) {
  Get-Help -Full -Name $PSCommandPath
  return
}

# ────────────────────────────────────────────────────────────────────────────
# * Load shared helpers (same set as Isolate-Incompatible-Mod.ps1).
# ────────────────────────────────────────────────────────────────────────────

$sharedUiPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LauncherUi.ps1"
if (-not (Test-Path -LiteralPath $sharedUiPath)) { throw ("Shared UI helpers not found: {0}" -f $sharedUiPath) }
. $sharedUiPath

$sharedLogPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LogTools.ps1"
if (-not (Test-Path -LiteralPath $sharedLogPath)) { throw ("Shared log helpers not found: {0}" -f $sharedLogPath) }
. $sharedLogPath

$sharedConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Config.ps1"
if (-not (Test-Path -LiteralPath $sharedConfigPath)) { throw ("Shared config helpers not found: {0}" -f $sharedConfigPath) }
. $sharedConfigPath

$sharedIsolationLauncherPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Launcher.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationLauncherPath)) { throw ("Shared isolation launcher helpers not found: {0}" -f $sharedIsolationLauncherPath) }
. $sharedIsolationLauncherPath

$sharedIsolationLogPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-LogParsing.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationLogPath)) { throw ("Shared isolation log helpers not found: {0}" -f $sharedIsolationLogPath) }
. $sharedIsolationLogPath

$sharedIsolationJarDepPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-JarDependencies.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationJarDepPath)) { throw ("Shared isolation jar dependency helpers not found: {0}" -f $sharedIsolationJarDepPath) }
. $sharedIsolationJarDepPath

$sharedIsolationQuarantinePath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Quarantine.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationQuarantinePath)) { throw ("Shared isolation quarantine helpers not found: {0}" -f $sharedIsolationQuarantinePath) }
. $sharedIsolationQuarantinePath

$sharedIsolationStrategyPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Strategy.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationStrategyPath)) { throw ("Shared isolation strategy helpers not found: {0}" -f $sharedIsolationStrategyPath) }
. $sharedIsolationStrategyPath

$sharedIsolationErrorDumpPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-ErrorDump.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationErrorDumpPath)) { throw ("Shared isolation error dump helpers not found: {0}" -f $sharedIsolationErrorDumpPath) }
. $sharedIsolationErrorDumpPath

$sharedIsolationHashCachePath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-HashCache.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationHashCachePath)) { throw ("Shared hash cache helpers not found: {0}" -f $sharedIsolationHashCachePath) }
. $sharedIsolationHashCachePath

# ────────────────────────────────────────────────────────────────────────────
# * Config.
# ────────────────────────────────────────────────────────────────────────────

$projectConfig = Import-ProjectConfig -StartDir $PSScriptRoot
$configIni = $projectConfig.Ini

$defaultGameModsDir = Join-Path -Path ([Environment]::GetFolderPath('ApplicationData')) -ChildPath '.tlauncher\legacy\Minecraft\game\mods'
if (-not $PSBoundParameters.ContainsKey("GameModsDir")) {
  $cfgGameModsDir = Get-IniValue -Ini $configIni -Section "Paths" -Key "GameModsDir" -Default ""
  $GameModsDir = $(if (-not [string]::IsNullOrWhiteSpace($cfgGameModsDir)) { $cfgGameModsDir } else { $defaultGameModsDir })
}
if (-not $PSBoundParameters.ContainsKey("StorageModsDir")) {
  $StorageModsDir = Get-IniValue -Ini $configIni -Section "Paths" -Key "StorageModsDir" -Default ""
}
if (-not $PSBoundParameters.ContainsKey("LogPath")) {
  $LogPath = Get-IniValue -Ini $configIni -Section "Paths" -Key "LogPath" -Default ""
}
if (-not $PSBoundParameters.ContainsKey("LauncherExePath")) {
  $LauncherExePath = Get-IniValue -Ini $configIni -Section "Paths" -Key "LauncherExePath" -Default ""
}

if ($BinaryLinearThreshold -lt 1) { $BinaryLinearThreshold = 1 }
$useDynamicSuccessConfirm = -not $PSBoundParameters.ContainsKey("SuccessConfirmSeconds")
$useDynamicOutcomeTimeout = -not $PSBoundParameters.ContainsKey("OutcomeTimeoutSeconds")
if ($SuccessConfirmSeconds -lt 10) { $SuccessConfirmSeconds = 10 }
# * In layering mode, OutcomeTimeoutSeconds serves as the sole stability check window.
# * Wait-ForOutcome already polls for crash/Fabric dialogs and process exits.
# * Override to SuccessConfirmSeconds to avoid double-waiting.
if ($useDynamicOutcomeTimeout -and (-not $useDynamicSuccessConfirm)) {
  $OutcomeTimeoutSeconds = $SuccessConfirmSeconds
}

# * Variables required by dot-sourced Shared-Isolation-Strategy.ps1 / JarDependencies.ps1.
# * PSScriptAnalyzer cannot see cross-script usage; suppress with explicit reference.
$UseDependencyAwareOrdering = $true
$DependencyAwareForceLinearIsolation = $false
$DependencyAwareExponentialMaxTier = 2
$UseLinearIsolation = $false
$null = $UseDependencyAwareOrdering, $DependencyAwareForceLinearIsolation, $UseLinearIsolation

# ────────────────────────────────────────────────────────────────────────────
# * Validate paths.
# ────────────────────────────────────────────────────────────────────────────

if (-not (Test-Path -LiteralPath $GameModsDir)) {
  throw ("GameModsDir not found: {0}" -f $GameModsDir)
}

$useStorage = -not [string]::IsNullOrWhiteSpace($StorageModsDir)
if ($useStorage -and (-not (Test-Path -LiteralPath $StorageModsDir))) {
  Write-Host ("Warning: StorageModsDir not found, storage operations are skipped: {0}" -f $StorageModsDir) -ForegroundColor Yellow
  $useStorage = $false
}

$script:EnableSessionLaunchConfigCache = (-not $NoCache)
$script:sessionSuccessfulLaunchConfigCache = @{}
if ($script:EnableSessionLaunchConfigCache) {
  Write-Host "Session launch-config cache: enabled." -ForegroundColor Gray
} else {
  Write-Host "Session launch-config cache: disabled (NoCache mode)." -ForegroundColor Gray
}

# ────────────────────────────────────────────────────────────────────────────
# * Build candidate list and dependency map.
# ────────────────────────────────────────────────────────────────────────────

$candidateMods = @(Get-ChildItem -LiteralPath $GameModsDir -Filter "*.jar" -File -ErrorAction Stop |
    Sort-Object -Property LastWriteTime)

$script:dependencyAwareTierByJarName = @{}
$script:currentDependencyTier = 0
$script:dependencyMapByModId = @{}
$script:dependencyMapProvidedIdsByJar = @{}
$script:dependencyMapScanPath = ""
$script:blockedByDependency = $false
$script:blockedDependencyMissing = @()
$script:blockedDependencyRequiring = @()
$script:blockedDependencyContext = ""

if ($ExcludeJarNames -and $ExcludeJarNames.Count -gt 0) {
  $excludeSet = @{}
  foreach ($name in $ExcludeJarNames) {
    if (-not [string]::IsNullOrWhiteSpace($name)) { $excludeSet[$name.ToLowerInvariant()] = $true }
  }
  $candidateMods = @($candidateMods | Where-Object { -not $excludeSet.ContainsKey($_.Name.ToLowerInvariant()) })
}

if (-not $candidateMods -or $candidateMods.Count -eq 0) {
  Write-Host "No jar mods found to test." -ForegroundColor Yellow
  exit 0
}

# * Build dependency map and classify mods into tiers.
if ($DependencyAwareTier2MaxDependents -lt 0) { $DependencyAwareTier2MaxDependents = 0 }
if ($DependencyAwareTier3MaxDependents -lt $DependencyAwareTier2MaxDependents) {
  $DependencyAwareTier3MaxDependents = $DependencyAwareTier2MaxDependents
}
if ($DependencyAwareQuickIsolateMaxTier -lt 0) { $DependencyAwareQuickIsolateMaxTier = 0 }
if ($DependencyAwareQuickIsolateMaxTier -gt 4) { $DependencyAwareQuickIsolateMaxTier = 4 }
if ($DependencyAwareExponentialMaxTier -lt 0) { $DependencyAwareExponentialMaxTier = 0 }
if ($DependencyAwareExponentialMaxTier -gt 4) { $DependencyAwareExponentialMaxTier = 4 }

$countMode = $DependencyAwareOrderingCountMode
if ([string]::IsNullOrWhiteSpace($countMode)) { $countMode = "RequiredOnly" }

$dependencyMap = $null
if ($DependencyMapSource -ne "Internal") {
  $dependencyMap = Get-DependencyMapFromSource -ScanPath $GameModsDir
}

$depMap = @{}
if ($dependencyMap) {
  Initialize-DependencyMapCache -DependencyMap $dependencyMap
  $depMap = Get-DependentModCountsFromDependencyMap -DependencyMap $dependencyMap -CountMode $countMode
  Write-Host ("Dependency map loaded from source: {0}" -f $DependencyMapSource) -ForegroundColor Gray
} else {
  if ($DependencyMapSource -ne "Internal") {
    Write-Host ("Warning: dependency map unavailable from source '{0}'. Falling back to internal parser." -f $DependencyMapSource) -ForegroundColor Yellow
  }
  $depMap = Get-DependentModCountsByJarName -ModsDir $GameModsDir -CountMode $countMode
}

if ($depMap -and $depMap.Count -gt 0) {
  foreach ($jarKey in $depMap.Keys) {
    $depCount = [int]$depMap[$jarKey].DependentCount
    $known = [bool]$depMap[$jarKey].Known
    if (-not $known -and (-not [bool]$DependencyAwareTreatUnknownAsCore)) {
      $depCount = 0
      $known = $true
    }
    $script:dependencyAwareTierByJarName[$jarKey] = Get-DependencyAwareTier -DependentCount $depCount -Known $known
  }

  foreach ($mod in $candidateMods) {
    $jarKey = $mod.Name.ToLowerInvariant()
    $depCount = -1
    $known = $false
    if ($depMap.ContainsKey($jarKey)) {
      $depCount = [int]$depMap[$jarKey].DependentCount
      $known = [bool]$depMap[$jarKey].Known
    }
    if (-not $known -and (-not [bool]$DependencyAwareTreatUnknownAsCore)) {
      $depCount = 0
      $known = $true
    }
    $tier = Get-DependencyAwareTier -DependentCount $depCount -Known $known
    Add-Member -InputObject $mod -NotePropertyName DependentModCount -NotePropertyValue $depCount -Force
    Add-Member -InputObject $mod -NotePropertyName DependentModTier -NotePropertyValue $tier -Force
    Add-Member -InputObject $mod -NotePropertyName DependentModCountKnown -NotePropertyValue $known -Force
  }
} else {
  Write-Host "Warning: dependency map is empty. Классификация по уровням недоступна; все моды считаются уровнем 1." -ForegroundColor Yellow
  foreach ($mod in $candidateMods) {
    Add-Member -InputObject $mod -NotePropertyName DependentModCount -NotePropertyValue 0 -Force
    Add-Member -InputObject $mod -NotePropertyName DependentModTier -NotePropertyValue 1 -Force
    Add-Member -InputObject $mod -NotePropertyName DependentModCountKnown -NotePropertyValue $true -Force
  }
}

# * Separate by tier: layer order is tier-3, tier-2, tier-1.
$tier4Mods = @($candidateMods | Where-Object { $_.DependentModTier -eq 4 })
$tier3Mods = @($candidateMods | Where-Object { $_.DependentModTier -eq 3 } | Sort-Object -Property LastWriteTime)
$tier2Mods = @($candidateMods | Where-Object { $_.DependentModTier -eq 2 } | Sort-Object -Property LastWriteTime)
$tier1AllMods = @($candidateMods | Where-Object { $_.DependentModTier -eq 1 } | Sort-Object -Property LastWriteTime)
$tier1Mods = @($tier1AllMods)

$nonCoreMods = @($tier3Mods) + @($tier2Mods) + @($tier1Mods)

# * Optional: skip mods that already passed in prior sessions (MCCC.json SHA256 cache).
$script:mcccCacheEnabled = $false
$script:mcccCachePath = ""
$script:mcccCache = $null
$script:mcccKnownGoodJarNameSet = @{}

if ((-not $DryRun) -and $UseHashCache) {
  $script:mcccCachePath = Get-McccHashCachePath -GameModsDir $GameModsDir -FileName $HashCacheFileName
  $script:mcccCache = Read-McccHashCache -Path $script:mcccCachePath
  $script:mcccCacheEnabled = $true

  # * Ensure the cache file exists so it can be inspected/edited by the user.
  try {
    if (-not [string]::IsNullOrWhiteSpace($script:mcccCachePath) -and -not (Test-Path -LiteralPath $script:mcccCachePath)) {
      Write-McccHashCache -Path $script:mcccCachePath -Cache $script:mcccCache
    }
  } catch {
    Write-Host ("Warning: failed to create hash cache file: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    $script:mcccCacheEnabled = $false
  }

  $passedCount = 0
  if ($script:mcccCacheEnabled -and $null -ne $script:mcccCache -and $script:mcccCache.ContainsKey("passed") -and ($script:mcccCache["passed"] -is [hashtable])) {
    $passedCount = $script:mcccCache["passed"].Count
  }

  if ($script:mcccCacheEnabled -and $passedCount -gt 0 -and $nonCoreMods -and $nonCoreMods.Count -gt 0) {
    foreach ($mod in $nonCoreMods) {
      $hash = Get-Sha256LowerHex -Path $mod.FullName -Retries $HashCacheHashRetryCount -DelayMs $HashCacheHashRetryDelayMs
      if ([string]::IsNullOrWhiteSpace($hash)) { continue }
      if (Test-McccHashPassed -Cache $script:mcccCache -Sha256LowerHex $hash) {
        $script:mcccKnownGoodJarNameSet[$mod.Name.ToLowerInvariant()] = $hash
      }
    }

    if ($script:mcccKnownGoodJarNameSet.Count -gt 0) {
      $tier3Mods = @($tier3Mods | Where-Object { -not $script:mcccKnownGoodJarNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
      $tier2Mods = @($tier2Mods | Where-Object { -not $script:mcccKnownGoodJarNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
      $tier1Mods = @($tier1Mods | Where-Object { -not $script:mcccKnownGoodJarNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
      $nonCoreMods = @($tier3Mods) + @($tier2Mods) + @($tier1Mods)
    }
  }
}

Write-Host ("Layering strategy. Total mods: {0}" -f $candidateMods.Count) -ForegroundColor Cyan
if ($script:mcccCacheEnabled -and $script:mcccKnownGoodJarNameSet.Count -gt 0) {
  Write-Host ("  Hash cache: skipping {0} previously passed mod(s)." -f $script:mcccKnownGoodJarNameSet.Count) -ForegroundColor Gray
}
Write-Host ("  Уровень 4 (core): {0} mod(s) - активны с начала" -f $tier4Mods.Count) -ForegroundColor Gray
Write-Host ("  Уровень 3 (слой 1): {0} mod(s)" -f $tier3Mods.Count) -ForegroundColor Gray
Write-Host ("  Уровень 2 (слой 2): {0} mod(s)" -f $tier2Mods.Count) -ForegroundColor Gray
Write-Host ("  Уровень 1 (слой 3): {0} mod(s)" -f $tier1Mods.Count) -ForegroundColor Gray

if ($nonCoreMods.Count -eq 0) {
  if ($script:mcccCacheEnabled -and $script:mcccKnownGoodJarNameSet.Count -gt 0) {
    Write-Host "All non-core mods are marked as passed in MCCC.json. Nothing to do." -ForegroundColor Green
  } else {
    Write-Host "No non-core mods to layer. Nothing to do." -ForegroundColor Yellow
  }
  exit 0
}

if ($DryRun) {
  Write-Host "--- Dry Run Plan ---" -ForegroundColor Cyan
  foreach ($mod in $tier4Mods) {
    Write-Host ("  [core] {0} | уровень=4 | dependents={1}" -f $mod.Name, $mod.DependentModCount) -ForegroundColor Gray
  }
  foreach ($tier in @(3, 2, 1)) {
    $tierMods = switch ($tier) { 3 { $tier3Mods } 2 { $tier2Mods } 1 { $tier1Mods } }
    foreach ($mod in $tierMods) {
      Write-Host ("  [layer] {0} | уровень={1} | dependents={2}" -f $mod.Name, $tier, $mod.DependentModCount) -ForegroundColor Gray
    }
  }
  Write-Host "Dry run complete. No changes made." -ForegroundColor Green
  exit 0
}

function Update-McccHashCachePassedJar {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$JarNames,
    [Parameter(Mandatory = $false)]
    [string]$Minecraft = ""
  )

  if (-not $script:mcccCacheEnabled) { return }
  if ($null -eq $script:mcccCache) { return }
  if ([string]::IsNullOrWhiteSpace($script:mcccCachePath)) { return }

  $dirty = $false
  foreach ($jarName in $JarNames) {
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
    $modPath = Join-Path -Path $GameModsDir -ChildPath $jarName
    if (-not (Test-Path -LiteralPath $modPath)) { continue }
    $hash = Add-McccPassedHash -Cache $script:mcccCache -JarName $jarName -FilePath $modPath -Minecraft $Minecraft `
      -HashRetries $HashCacheHashRetryCount -HashDelayMs $HashCacheHashRetryDelayMs
    if (-not [string]::IsNullOrWhiteSpace($hash)) { $dirty = $true }
  }

  if (-not $dirty) { return }
  try {
    if ($PSCmdlet.ShouldProcess($script:mcccCachePath, "Update MCCC hash cache")) {
      Write-McccHashCache -Path $script:mcccCachePath -Cache $script:mcccCache
    }
  } catch {
    Write-Host ("Warning: failed to update hash cache: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
  }
}

# ────────────────────────────────────────────────────────────────────────────
# * Setup quarantine dirs and state.
# ────────────────────────────────────────────────────────────────────────────

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$gameLegacyRoot = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
$gameLegacyTempRoot = Join-Path -Path $gameLegacyRoot -ChildPath "temp"
$gameQuarantineDir = Join-Path -Path $gameLegacyTempRoot -ChildPath ("layer-{0}" -f $runId)
$storageQuarantineDir = $null
if ($useStorage) {
  $storageLegacyRoot = Join-Path -Path $StorageModsDir -ChildPath $StorageLegacyFolderName
  $storageLegacyTempRoot = Join-Path -Path $storageLegacyRoot -ChildPath "temp"
  $storageQuarantineDir = Join-Path -Path $storageLegacyTempRoot -ChildPath ("layer-{0}" -f $runId)
}

Write-Host ("Quarantine dir: {0}" -f $gameQuarantineDir) -ForegroundColor Gray

$movedItems = New-Object System.Collections.Generic.List[object]
$movedJarNameSet = @{}
# * Used by dot-sourced Shared-Isolation-Strategy.ps1 (Invoke-IsolationProbe).
$pinnedJarNameSet = @{}; $null = $pinnedJarNameSet
$script:lastBaselinePinnedKey = ""
$script:lastOutcomeHandleId = 0
$script:activeBaselineSignature = ""
$script:activeBaselineEvidenceKey = ""
$mcVersionForLegacy = "unknown"
$exitCode = 0
$abortLayering = $false
$culpritJarNames = New-Object System.Collections.Generic.List[string]
$culpritEvidenceKeys = @{}
$culpritMoves = New-Object System.Collections.Generic.List[object]
$hadError = $false
$wasCtrlC = $false
$hadUnresolvableFabric = $false
$phase = "init"
$layeringStartTime = Get-Date

# ────────────────────────────────────────────────────────────────────────────
# * Helper: Attempt to identify culprit from crash log (basic algorithm).
# ────────────────────────────────────────────────────────────────────────────

function Find-CulpritFromLog {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$LogLines,
    [Parameter(Mandatory = $true)]
    [object[]]$BatchMods
  )

  $modIds = @(Get-IncompatibleModIdsFromLog -Lines $LogLines -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible))
  if (-not $modIds -or $modIds.Count -eq 0) { return @() }

  $batchNameSet = @{}
  foreach ($m in $BatchMods) { $batchNameSet[$m.Name.ToLowerInvariant()] = $true }

  $searchDirs = @($GameModsDir)
  if ($gameQuarantineDir -and (Test-Path -LiteralPath $gameQuarantineDir)) { $searchDirs += $gameQuarantineDir }

  $jars = Find-ModJarByIdBestEffort -Dirs $searchDirs -ModIds $modIds -AllowTokenFallback:$false
  if (-not $jars -or $jars.Count -eq 0) { return @() }

  # * Only return jars that are in the current batch (not tier-4 or already-active mods).
  $matched = @($jars | Where-Object { $batchNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
  return $matched
}

# ────────────────────────────────────────────────────────────────────────────
# * Helper: Move culprit to legacy.
# ────────────────────────────────────────────────────────────────────────────

function Move-CulpritToLegacy {
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarName,
    [Parameter(Mandatory = $false)]
    [string]$EvidenceKey = ""
  )

  $culpritJarNames.Add($JarName)
  if (-not [string]::IsNullOrWhiteSpace($EvidenceKey)) {
    $culpritEvidenceKeys[$JarName] = $EvidenceKey
  }

  # * Ensure the jar is in quarantine first (game + storage sides).
  $gamePath = Join-Path -Path $GameModsDir -ChildPath $JarName
  $storagePath = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $JarName } else { $null }
  $gameDest = $null
  $storageDest = $null
  if (Test-Path -LiteralPath $gamePath) {
    $gameDest = Move-ToQuarantine -SourcePath $gamePath -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
  }
  if ($useStorage -and $storagePath -and (Test-Path -LiteralPath $storagePath) -and $storageQuarantineDir) {
    $storageDest = Move-ToQuarantine -SourcePath $storagePath -DestDir $storageQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
  }
  if ($null -ne $gameDest -or $null -ne $storageDest) {
    [void](Add-MovedItemRecord -JarName $JarName `
        -GameSource $gamePath `
        -GameQuarantine $gameDest `
        -StorageSource $storagePath `
        -StorageQuarantine $storageDest)
  }

  Write-Host ("Culprit identified: {0}" -f $JarName) -ForegroundColor Green
}

# ────────────────────────────────────────────────────────────────────────────
# * Helper: Tier-1 narrowing for faster crash isolation.
# ────────────────────────────────────────────────────────────────────────────

function Invoke-Tier1BatchNarrowing {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$BatchJarNames
  )

  $batchSet = @{}
  foreach ($name in @($BatchJarNames)) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $batchSet[$name.ToLowerInvariant()] = $true
  }

  $parked = New-Object System.Collections.Generic.List[string]

  foreach ($tier1Mod in $tier1AllMods) {
    $jarName = [string]$tier1Mod.Name
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
    $jarKey = $jarName.ToLowerInvariant()
    if ($batchSet.ContainsKey($jarKey)) { continue }
    if ($culpritJarNames.Contains($jarName)) { continue }
    # * Already quarantined.
    if ($movedJarNameSet.ContainsKey($jarName)) { continue }

    $gamePath = Join-Path -Path $GameModsDir -ChildPath $jarName
    $storagePath = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $jarName } else { $null }
    $gameDest = $null
    $storageDest = $null

    if (Test-Path -LiteralPath $gamePath) {
      $gameDest = Move-ToQuarantine -SourcePath $gamePath -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
    }
    if ($useStorage -and $storagePath -and (Test-Path -LiteralPath $storagePath) -and $storageQuarantineDir) {
      $storageDest = Move-ToQuarantine -SourcePath $storagePath -DestDir $storageQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
    }

    if ($null -ne $gameDest -or $null -ne $storageDest) {
      [void](Add-MovedItemRecord -JarName $jarName `
          -GameSource $gamePath `
          -GameQuarantine $gameDest `
          -StorageSource $storagePath `
          -StorageQuarantine $storageDest)
      $parked.Add($jarName)
    }
  }

  if ($parked.Count -gt 0) {
    Write-Host ("  Сужение уровня 1: запарковано {0} активных модов уровня 1 вне текущего батча." -f $parked.Count) -ForegroundColor Gray
  }

  return @($parked.ToArray())
}

function Restore-Tier1BatchNarrowing {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$ParkedJarNames
  )

  $restored = 0
  foreach ($jarName in @($ParkedJarNames | Sort-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }

    $item = Get-MovedItemByJarName -JarName $jarName
    if ($null -eq $item) { continue }

    $didRestore = $false
    if ($null -ne $item.GameQuarantine -and (Test-Path -LiteralPath $item.GameQuarantine)) {
      [void](Restore-FromQuarantine -SourcePath $item.GameQuarantine -DestDir $GameModsDir -IsDryRun $false -AllowOverwrite $true)
      $item.GameQuarantine = $null
      $didRestore = $true
    }
    if ($useStorage -and $null -ne $item.StorageQuarantine -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
      [void](Restore-FromQuarantine -SourcePath $item.StorageQuarantine -DestDir $StorageModsDir -IsDryRun $false -AllowOverwrite $true)
      $item.StorageQuarantine = $null
      $didRestore = $true
    }

    if ($didRestore) {
      if ($movedJarNameSet.ContainsKey($jarName)) {
        $null = $movedJarNameSet.Remove($jarName)
      }
      $restored++
    }
  }

  if ($restored -gt 0) {
    Write-Host ("  Сужение уровня 1: восстановлено {0} запаркованных модов уровня 1." -f $restored) -ForegroundColor Gray
  }

  return $restored
}

function Complete-Tier1BatchNarrowing {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$ParkedJarNames,
    [Parameter(Mandatory = $true)]
    [bool]$RunConsistencyProbe,
    [Parameter(Mandatory = $false)]
    [string]$ProbePhasePrefix = "tier1_narrowing_probe"
  )

  if (-not $ParkedJarNames -or $ParkedJarNames.Count -eq 0) {
    return $true
  }

  [void](Restore-Tier1BatchNarrowing -ParkedJarNames $ParkedJarNames)

  if (-not $RunConsistencyProbe) { return $true }

  Write-Host "  Сужение уровня 1: контрольный запуск с восстановленным уровнем 1." -ForegroundColor Cyan
  $probeResult = Invoke-LayeringLaunchAndCheck -PhasePrefix $ProbePhasePrefix
  if ($probeResult.Type -eq "Success" -or $probeResult.Type -eq "UserExit") {
    return $true
  }

  Write-Host ("  Контрольный запуск уровня 1 провалился после восстановления модов: {0}" -f $probeResult.Type) -ForegroundColor Yellow
  return $false
}

# ────────────────────────────────────────────────────────────────────────────
# * Helper: Wait for game exit; force-kill if the process hangs after crash.
# ────────────────────────────────────────────────────────────────────────────

function Wait-GameExitOrForceKill {
  <#
  .SYNOPSIS
  Waits for game processes to exit. If they don't exit within the configured timeout,
  force-kills them so the launcher can reappear.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [datetime]$StartedAfter
  )

  $exited = Wait-ConfiguredGameExit -StartedAfter $StartedAfter
  if (-not $exited) {
    Write-Host "Force-killing hanging game processes." -ForegroundColor Yellow
    [void](Stop-ConfiguredGameProcess -StartedAfter $layeringStartTime)
    # * Give the launcher a moment to reappear after the forced kill.
    Start-Sleep -Seconds 3
  }
}

# ────────────────────────────────────────────────────────────────────────────
# * Helper: Launch, wait for full success confirmation, then kill game.
# ────────────────────────────────────────────────────────────────────────────

function Invoke-LayeringLaunchAndCheck {
  <#
  .SYNOPSIS
  Launches the game and returns the outcome. On Timeout (initial success signal),
  waits SuccessConfirmSeconds more to confirm stability, then kills the game.
  Detects user-initiated game closure (ProcessExit without crash dialog) as UserExit.
  #>
  param(
    [Parameter(Mandatory = $false)]
    [string]$PhasePrefix = "layer",
    [Parameter(Mandatory = $false)]
    [switch]$LeaveGameRunning
  )

  $ignoreHandles = @()
  if ($script:lastOutcomeHandleId -ne 0) {
    $ignoreHandles = @($script:lastOutcomeHandleId)
  }

  if ($useDynamicOutcomeTimeout -or $useDynamicSuccessConfirm) {
    $activeModCount = Get-ActiveModCount -ModsDir $GameModsDir
    $perModSeconds = if ($LongLaunchTimeout) { $launchWaitPerModSecondsLong } else { $launchWaitPerModSeconds }
    $scaledLaunchSeconds = Get-ScaledLaunchWaitTime -ActiveModCount $activeModCount `
      -PerModSeconds $perModSeconds `
      -BaseSeconds $launchWaitBaseSeconds
    if ($useDynamicOutcomeTimeout) { $OutcomeTimeoutSeconds = $scaledLaunchSeconds }
  }

  $attemptStart = Get-Date
  $script:phase = ("{0}_invoke_launch" -f $PhasePrefix)
  $outcome = Invoke-ConfiguredLaunchAttempt -IgnoreHandleIds $ignoreHandles

  # * Check for late Fabric dialog.
  if ($outcome.Type -ne "FabricDialog") {
    $fabricWindowNow = Select-WindowByTitlePattern -Patterns $FabricWindowTitlePatterns
    if ($null -ne $fabricWindowNow) {
      Write-Host ("Detected Fabric dialog after outcome: {0}" -f $fabricWindowNow.Title) -ForegroundColor Yellow
      $outcome = [pscustomobject]@{
        Type = "FabricDialog"
        Window = $fabricWindowNow
      }
    }
  }

  # * Check for late crash dialog.
  if ($outcome.Type -ne "FabricDialog" -and $outcome.Type -ne "CrashDialog") {
    $crashWindowNow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
    if ($null -ne $crashWindowNow) {
      Write-Host ("Detected crash dialog after outcome: {0}" -f $crashWindowNow.Title) -ForegroundColor Yellow
      $outcome = [pscustomobject]@{
        Type = "CrashDialog"
        Window = $crashWindowNow
      }
    }
  }

  Write-Host ("Outcome: {0}" -f $outcome.Type) -ForegroundColor $(if ($outcome.Type -eq "Timeout") { "Green" } else { "Yellow" })

  if ($outcome.Type -eq "FabricDialog") {
    if ($null -ne $outcome.Window) {
      $script:phase = ("{0}_close_fabric" -f $PhasePrefix)
      $script:lastOutcomeHandleId = Close-OutcomeWindowWithExtraDialog -Outcome $outcome `
        -DelaySeconds $CrashCloseDelaySeconds `
        -OffsetX $CrashCloseClickOffsetX `
        -OffsetY $CrashCloseClickOffsetY `
        -CloseExtraFabricDialogs $true
    }
    $script:phase = ("{0}_wait_game_exit_fabric" -f $PhasePrefix)
    Wait-GameExitOrForceKill -StartedAfter $attemptStart
    Start-Sleep -Seconds $LogPostRunDelaySeconds
    $snapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $attemptStart
    $requiringIds = @(Get-FabricRequiringModId -Lines $snapshot.Lines) |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    $missingIds = @(Get-FabricMissingDependencyId -Lines $snapshot.Lines) |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    Wait-ConfiguredLauncherInteractive
    return [pscustomobject]@{
      Type = "FabricDialog"
      AttemptStart = $attemptStart
      RequiringModIds = @($requiringIds)
      MissingDepIds = @($missingIds)
      LogSnapshot = $snapshot
    }
  }

  # * ProcessExit: distinguish real crash from user-initiated game closure.
  if ($outcome.Type -eq "ProcessExit") {
    $script:phase = ("{0}_wait_game_exit_process" -f $PhasePrefix)
    Wait-GameExitOrForceKill -StartedAfter $attemptStart
    Start-Sleep -Seconds $LogPostRunDelaySeconds
    # * Give crash dialog a moment to appear after the process exits.
    Start-Sleep -Seconds 2
    $crashWindowAfter = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
    if ($null -ne $crashWindowAfter) {
      # * Crash dialog appeared after ProcessExit -> real crash.
      $script:phase = ("{0}_close_crash_after_exit" -f $PhasePrefix)
      $script:lastOutcomeHandleId = Close-OutcomeWindowWithExtraDialog `
        -Outcome ([pscustomobject]@{ Type = "CrashDialog"; Window = $crashWindowAfter }) `
        -DelaySeconds $CrashCloseDelaySeconds `
        -OffsetX $CrashCloseClickOffsetX `
        -OffsetY $CrashCloseClickOffsetY `
        -CloseExtraFabricDialogs $true
      $snapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $attemptStart
      Wait-ConfiguredLauncherInteractive
      return [pscustomobject]@{
        Type = "Crash"
        AttemptStart = $attemptStart
        LogSnapshot = $snapshot
      }
    }
    # * No crash dialog. If the launcher is visible -> user likely closed the game.
    $launcherAfter = Select-WindowByTitlePattern -Patterns @($LauncherWindowTitlePattern)
    if ($null -ne $launcherAfter) {
      Write-Host "Game exited without crash dialog. Likely user intervention." -ForegroundColor Yellow
      return [pscustomobject]@{
        Type = "UserExit"
        AttemptStart = $attemptStart
      }
    }
    # * No crash dialog, no launcher -> ambiguous. Read log and treat as crash.
    $snapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $attemptStart
    Wait-ConfiguredLauncherInteractive
    return [pscustomobject]@{
      Type = "Crash"
      AttemptStart = $attemptStart
      LogSnapshot = $snapshot
    }
  }

  if ($outcome.Type -eq "CrashDialog") {
    if ($null -ne $outcome.Window) {
      $script:phase = ("{0}_close_crash" -f $PhasePrefix)
      $script:lastOutcomeHandleId = Close-OutcomeWindowWithExtraDialog -Outcome $outcome `
        -DelaySeconds $CrashCloseDelaySeconds `
        -OffsetX $CrashCloseClickOffsetX `
        -OffsetY $CrashCloseClickOffsetY `
        -CloseExtraFabricDialogs $true
    }
    $script:phase = ("{0}_wait_game_exit_crash" -f $PhasePrefix)
    Wait-GameExitOrForceKill -StartedAfter $attemptStart
    Start-Sleep -Seconds $LogPostRunDelaySeconds
    $snapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $attemptStart
    Wait-ConfiguredLauncherInteractive
    return [pscustomobject]@{
      Type = "Crash"
      AttemptStart = $attemptStart
      LogSnapshot = $snapshot
    }
  }

  # * Timeout = success. OutcomeTimeoutSeconds equals SuccessConfirmSeconds, so the
  # * outcome detection loop already served as the stability check.
  Write-Host ("Launch confirmed stable ({0}s)." -f $OutcomeTimeoutSeconds) -ForegroundColor Green
  if ($LeaveGameRunning) {
    Write-Host "Game left running (final batch)." -ForegroundColor Green
  } else {
    Write-Host "Stopping game for next layer." -ForegroundColor Cyan
    $script:phase = ("{0}_stop_game" -f $PhasePrefix)
    [void](Stop-ConfiguredGameProcess -StartedAfter $layeringStartTime)
    [void](Wait-ConfiguredGameExit -StartedAfter $attemptStart -WarningContext "Next layer")
    Wait-ConfiguredLauncherInteractive
  }

  $launchConfigKey = ""
  if ($outcome | Get-Member -Name "LaunchConfigKey" -MemberType NoteProperty, Property) {
    $launchConfigKey = [string]$outcome.LaunchConfigKey
  }
  if (-not [string]::IsNullOrWhiteSpace($launchConfigKey)) {
    Register-SessionLaunchConfigSuccess -ConfigKey $launchConfigKey
  }

  return [pscustomobject]@{
    Type = "Success"
    AttemptStart = $attemptStart
  }
}

# ────────────────────────────────────────────────────────────────────────────
# * Helper: Restore missing dependencies from quarantine on Fabric dialog.
# ────────────────────────────────────────────────────────────────────────────

function Restore-MissingDependency {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$MissingDepIds
  )

  $missingArr = @($MissingDepIds |
      ForEach-Object { [string]$_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.ToLowerInvariant() } |
      Sort-Object -Unique)
  if (-not $missingArr -or $missingArr.Count -eq 0) { return 0 }

  # * Print a compact summary to make dependency recovery visible and debuggable.
  $preview = @($missingArr | Select-Object -First 10)
  $suffix = if ($missingArr.Count -gt $preview.Count) { " (+{0} more)" -f ($missingArr.Count - $preview.Count) } else { "" }
  Write-Host ("  Fabric missing dependencies: {0}{1}" -f ($preview -join ", "), $suffix) -ForegroundColor Gray

  # * Index moved items by jar name for fast lookup.
  $movedByJarKey = @{}
  foreach ($item in $movedItems) {
    if ($null -eq $item) { continue }
    $jarName = [string]$item.JarName
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
    $movedByJarKey[$jarName.ToLowerInvariant()] = $item
  }

  function Get-QuarantineLastWriteTimeSafe {
    param(
      [Parameter(Mandatory = $true)]
      [AllowEmptyString()]
      [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return [datetime]::MinValue }
    try {
      return (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTime
    } catch {
      return [datetime]::MinValue
    }
  }

  # * Resolve missing dependency ids to jar names using the dependency map (preferred).
  $jarNamesToRestore = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $unresolved = New-Object System.Collections.Generic.List[string]

  foreach ($idKey in $missingArr) {
    $bestJarName = ""
    $bestTime = [datetime]::MinValue

    if ($script:dependencyMapByModId -and $script:dependencyMapByModId.Count -gt 0 -and $script:dependencyMapByModId.ContainsKey($idKey)) {
      foreach ($candJarName in @($script:dependencyMapByModId[$idKey])) {
        if ([string]::IsNullOrWhiteSpace($candJarName)) { continue }
        $candKey = $candJarName.ToLowerInvariant()
        if (-not $movedByJarKey.ContainsKey($candKey)) { continue }

        $candItem = $movedByJarKey[$candKey]
        $t = [datetime]::MinValue
        if ($null -ne $candItem.GameQuarantine -and (Test-Path -LiteralPath $candItem.GameQuarantine)) {
          $t = Get-QuarantineLastWriteTimeSafe -Path $candItem.GameQuarantine
        } elseif ($useStorage -and $null -ne $candItem.StorageQuarantine -and (Test-Path -LiteralPath $candItem.StorageQuarantine)) {
          $t = Get-QuarantineLastWriteTimeSafe -Path $candItem.StorageQuarantine
        } else {
          continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$candItem.JarName)) { continue }
        if ($t -gt $bestTime) {
          $bestTime = $t
          $bestJarName = [string]$candItem.JarName
        }
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($bestJarName)) {
      $null = $jarNamesToRestore.Add($bestJarName)
      continue
    }

    # * Fallback: strict jar name match (NO token matching) to avoid accidental mass restores.
    $fallbackMatched = $false
    foreach ($jarKey in $movedByJarKey.Keys) {
      if ($jarKey -like ("*{0}*" -f $idKey)) {
        $candItem = $movedByJarKey[$jarKey]
        if ($null -eq $candItem) { continue }
        $candJarName = [string]$candItem.JarName
        if ([string]::IsNullOrWhiteSpace($candJarName)) { continue }
        if ($null -eq $candItem.GameQuarantine -or -not (Test-Path -LiteralPath $candItem.GameQuarantine)) {
          if (-not $useStorage -or $null -eq $candItem.StorageQuarantine -or -not (Test-Path -LiteralPath $candItem.StorageQuarantine)) {
            continue
          }
        }
        $null = $jarNamesToRestore.Add($candJarName)
        $fallbackMatched = $true
        break
      }
    }
    if (-not $fallbackMatched) {
      $unresolved.Add($idKey) | Out-Null
    }
  }

  if ($unresolved.Count -gt 0) {
    $unresolvedPreview = @($unresolved | Sort-Object -Unique | Select-Object -First 10)
    $unresolvedSuffix = if ($unresolved.Count -gt $unresolvedPreview.Count) { " (+{0} more)" -f ($unresolved.Count - $unresolvedPreview.Count) } else { "" }
    Write-Host ("  Missing deps not found in quarantine: {0}{1}" -f ($unresolvedPreview -join ", "), $unresolvedSuffix) -ForegroundColor Yellow
  }

  $restored = 0
  foreach ($jarName in ($jarNamesToRestore | Sort-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
    $key = $jarName.ToLowerInvariant()
    if (-not $movedByJarKey.ContainsKey($key)) { continue }
    $item = $movedByJarKey[$key]
    if ($null -eq $item) { continue }

    $didRestore = $false
    if ($null -ne $item.GameQuarantine -and (Test-Path -LiteralPath $item.GameQuarantine)) {
      Write-Host ("Restoring missing dependency: {0}" -f $jarName) -ForegroundColor Cyan
      [void](Restore-FromQuarantine -SourcePath $item.GameQuarantine -DestDir $GameModsDir -IsDryRun $false -AllowOverwrite $true)
      $item.GameQuarantine = $null
      $didRestore = $true
    }
    if ($useStorage -and $null -ne $item.StorageQuarantine -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
      if (-not $didRestore) {
        Write-Host ("Restoring missing dependency: {0}" -f $jarName) -ForegroundColor Cyan
      }
      [void](Restore-FromQuarantine -SourcePath $item.StorageQuarantine -DestDir $StorageModsDir -IsDryRun $false -AllowOverwrite $true)
      $item.StorageQuarantine = $null
      $didRestore = $true
    }
    if (-not $didRestore) { continue }

    if ($movedJarNameSet.ContainsKey($jarName)) {
      $null = $movedJarNameSet.Remove($jarName)
    }
    $restored++
  }

  return $restored
}

# ────────────────────────────────────────────────────────────────────────────
# * Main execution.
# ────────────────────────────────────────────────────────────────────────────

try {
  # ── Phase 1: quarantine all non-tier-4 mods. ──
  $phase = "initial_quarantine"
  Write-Host "Quarantining all non-core mods..." -ForegroundColor Cyan
  foreach ($mod in $nonCoreMods) {
    $gameDest = Move-ToQuarantine -SourcePath $mod.FullName -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
    $storageDest = $null
    if ($useStorage) {
      $storagePath = Join-Path -Path $StorageModsDir -ChildPath $mod.Name
      if (Test-Path -LiteralPath $storagePath) {
        $storageDest = Move-ToQuarantine -SourcePath $storagePath -DestDir $storageQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
      }
    }
    [void](Add-MovedItemRecord -JarName $mod.Name `
        -GameSource $mod.FullName `
        -GameQuarantine $gameDest `
        -StorageSource $(if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $mod.Name } else { $null }) `
        -StorageQuarantine $storageDest)
  }
  Write-Host ("Quarantined {0} non-core mod(s)." -f $nonCoreMods.Count) -ForegroundColor Gray

  # ── Phase 2: baseline launch with tier-4 only. ──
  $phase = "baseline_tier4"
  $baselineLabel = "Baseline: launching with core libraries only (tier 4)."
  if ($script:mcccCacheEnabled -and $script:mcccKnownGoodJarNameSet.Count -gt 0) {
    $baselineLabel = "Baseline: launching with core libraries (tier 4) plus hash-cached mods."
  }
  Write-Host $baselineLabel -ForegroundColor Cyan
  $baselineResult = Invoke-LayeringLaunchAndCheck -PhasePrefix "baseline_tier4"

  if ($baselineResult.Type -eq "Crash") {
    Write-Host "Core-библиотеки (уровень 4) сами по себе вызывают краш. Наслоение невозможно." -ForegroundColor Red
    Write-Host "Требуется ручная диагностика: проверьте моды уровня 4 или используйте стандартную изоляцию." -ForegroundColor Yellow
    $exitCode = 2
    # ! Fall through to finally for restore.
  } elseif ($baselineResult.Type -eq "FabricDialog") {
    $restoredCount = Restore-MissingDependency -MissingDepIds $baselineResult.MissingDepIds
    if ($restoredCount -gt 0) {
      Write-Host ("Восстановлено {0} отсутствующих зависимостей для уровня 4. Повторный запуск..." -f $restoredCount) -ForegroundColor Cyan
      $baselineResult = Invoke-LayeringLaunchAndCheck -PhasePrefix "baseline_tier4_retry"
      if ($baselineResult.Type -ne "Success") {
        Write-Host ("Повторный запуск уровня 4 провалился: {0}. Невозможно продолжить." -f $baselineResult.Type) -ForegroundColor Red
        $exitCode = 2
      }
    } else {
      Write-Host "Базовая проверка уровня 4 показала диалог Fabric, но восстанавливаемых зависимостей не найдено." -ForegroundColor Red
      $exitCode = 2
    }
  }

  if ($baselineResult.Type -eq "Success" -and $baselineResult.PSObject.Properties.Name -contains "LogSnapshot") {
    $mcVersionForLegacy = Get-MinecraftVersionFromLog -Lines $baselineResult.LogSnapshot.Lines
  }

  if ($baselineResult.Type -eq "Success") {
    $tier4Names = @($tier4Mods | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    Update-McccHashCachePassedJar -JarNames $tier4Names -Minecraft $mcVersionForLegacy
  }

  # ── Phase 3: layering loop (tier-3, tier-2, tier-1). ──
  if ($exitCode -eq 0) {
    $layerTiers = @(
      @{ Tier = 3; Mods = $tier3Mods },
      @{ Tier = 2; Mods = $tier2Mods },
      @{ Tier = 1; Mods = $tier1Mods }
    )

    for ($tierIdx = 0; $tierIdx -lt $layerTiers.Count; $tierIdx++) {
      $tierInfo = $layerTiers[$tierIdx]
      $tier = $tierInfo.Tier
      $tierMods = @($tierInfo.Mods)
      if (-not $tierMods -or $tierMods.Count -eq 0) { continue }

      # * Skip mods already moved to legacy (found as culprits in previous tiers).
      $tierMods = @($tierMods | Where-Object { -not $culpritJarNames.Contains($_.Name) })
      # * Skip mods already restored (e.g. as dependencies).
      $tierMods = @($tierMods | Where-Object { $movedJarNameSet.ContainsKey($_.Name) })
      if (-not $tierMods -or $tierMods.Count -eq 0) { continue }

      Write-Host ("Наслоение, уровень {0}: {1} mod(s)" -f $tier, $tierMods.Count) -ForegroundColor Cyan

      $remaining = [System.Collections.Generic.List[object]]::new(@($tierMods))
      $batchSize = 1
      $maxFabricRetries = 5
      $consecutiveFabricFails = 0
      $maxConsecutiveFabricFails = 3

      while ($remaining.Count -gt 0) {
        if ($abortLayering) { break }

        $actualBatchSize = [Math]::Min($batchSize, $remaining.Count)
        $batch = @($remaining.GetRange(0, $actualBatchSize))
        $batchNames = @($batch | ForEach-Object { $_.Name })

        $batchDisplay = if ($VerbosePreference -ne "SilentlyContinue") { $batchNames -join ", " } else { (($batchNames | Select-Object -First 3) -join ", ") + $(if ($batchNames.Count -gt 3) { "..." } else { "" }) }
        Write-Host ("  Adding batch of {0} mod(s): {1}" -f $batch.Count, $batchDisplay) -ForegroundColor Cyan

        # * Restore batch from quarantine.
        $phase = ("tier{0}_restore_batch" -f $tier)
        foreach ($batchMod in $batch) {
          $item = Get-MovedItemByJarName -JarName $batchMod.Name
          if ($null -ne $item -and $null -ne $item.GameQuarantine -and (Test-Path -LiteralPath $item.GameQuarantine)) {
            [void](Restore-FromQuarantine -SourcePath $item.GameQuarantine -DestDir $GameModsDir -IsDryRun $false -AllowOverwrite $true)
            $item.GameQuarantine = $null
          }
          if ($useStorage -and $null -ne $item -and $null -ne $item.StorageQuarantine -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
            [void](Restore-FromQuarantine -SourcePath $item.StorageQuarantine -DestDir $StorageModsDir -IsDryRun $false -AllowOverwrite $true)
            $item.StorageQuarantine = $null
          }
          if ($movedJarNameSet.ContainsKey($batchMod.Name)) {
            $null = $movedJarNameSet.Remove($batchMod.Name)
          }
        }

        # * Determine if this is the final batch (last batch of last tier with mods).
        $isLastBatchInTier = ($remaining.Count -le $actualBatchSize)
        $hasMoreTierMods = $false
        for ($futureIdx = $tierIdx + 1; $futureIdx -lt $layerTiers.Count; $futureIdx++) {
          $futureMods = @($layerTiers[$futureIdx].Mods)
          $futureMods = @($futureMods | Where-Object { -not $culpritJarNames.Contains($_.Name) })
          $futureMods = @($futureMods | Where-Object { $movedJarNameSet.ContainsKey($_.Name) })
          if ($futureMods.Count -gt 0) { $hasMoreTierMods = $true; break }
        }
        $isFinalBatch = $isLastBatchInTier -and (-not $hasMoreTierMods)

        # * Launch and check.
        $phase = ("tier{0}_layer_launch" -f $tier)
        $layerResult = Invoke-LayeringLaunchAndCheck -PhasePrefix ("tier{0}_batch" -f $tier) -LeaveGameRunning:$isFinalBatch

        # * User closed the game manually. No crash dialog = game was running fine.
        if ($layerResult.Type -eq "UserExit") {
          Write-Host "  User closed the game. Treating batch as clean." -ForegroundColor Yellow
          Update-McccHashCachePassedJar -JarNames $batchNames -Minecraft $mcVersionForLegacy
          $null = $remaining.RemoveRange(0, $actualBatchSize)
          $batchSize = $batchSize * 2
          Write-Host ("  Remaining: {0}" -f $remaining.Count) -ForegroundColor Green
          continue
        }

        if ($layerResult.Type -eq "Success") {
          # * Batch is clean. Advance.
          $null = $remaining.RemoveRange(0, $actualBatchSize)
          $batchSize = $batchSize * 2
          $consecutiveFabricFails = 0
          Write-Host ("  Batch clean. Remaining: {0}" -f $remaining.Count) -ForegroundColor Green
          Update-McccHashCachePassedJar -JarNames $batchNames -Minecraft $mcVersionForLegacy
          continue
        }

        if ($layerResult.Type -eq "FabricDialog") {
          # * Missing dependencies — restore them and retry same batch.
          $fabricRetry = 0
          while ($layerResult.Type -eq "FabricDialog" -and $fabricRetry -lt $maxFabricRetries) {
            $fabricRetry++
            $restoredCount = Restore-MissingDependency -MissingDepIds $layerResult.MissingDepIds
            if ($restoredCount -eq 0) {
              Write-Host "  Fabric dialog but no restorable dependencies. Treating as crash." -ForegroundColor Yellow
              break
            }
            Write-Host ("  Restored {0} dep(s). Retrying batch..." -f $restoredCount) -ForegroundColor Cyan
            $layerResult = Invoke-LayeringLaunchAndCheck -PhasePrefix ("tier{0}_fabric_retry" -f $tier) -LeaveGameRunning:$isFinalBatch
          }

          if ($layerResult.Type -eq "Success") {
            $null = $remaining.RemoveRange(0, $actualBatchSize)
            $batchSize = $batchSize * 2
            $consecutiveFabricFails = 0
            Write-Host ("  Batch clean after dep restore. Remaining: {0}" -f $remaining.Count) -ForegroundColor Green
            Update-McccHashCachePassedJar -JarNames $batchNames -Minecraft $mcVersionForLegacy
            continue
          }
          if ($layerResult.Type -eq "FabricDialog") {
            # * Re-quarantine the problematic batch mods so they don't contaminate
            # * subsequent batches and tiers.
            Write-Host ("  Persistent Fabric dialog. Re-quarantining batch of {0} mod(s)." -f $batch.Count) -ForegroundColor Yellow
            foreach ($batchMod in $batch) {
              $gamePath = Join-Path -Path $GameModsDir -ChildPath $batchMod.Name
              if (Test-Path -LiteralPath $gamePath) {
                $dest = Move-ToQuarantine -SourcePath $gamePath -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
                if ($null -ne $dest) {
                  $existingItem = Get-MovedItemByJarName -JarName $batchMod.Name
                  if ($null -ne $existingItem) {
                    $existingItem.GameQuarantine = $dest
                  } else {
                    [void](Add-MovedItemRecord -JarName $batchMod.Name -GameSource $gamePath -GameQuarantine $dest -StorageSource $null -StorageQuarantine $null)
                  }
                  if (-not $movedJarNameSet.ContainsKey($batchMod.Name)) {
                    $movedJarNameSet[$batchMod.Name] = $true
                  }
                }
              }
            }
            $null = $remaining.RemoveRange(0, $actualBatchSize)
            $batchSize = 1
            $hadUnresolvableFabric = $true
            $consecutiveFabricFails++
            if ($consecutiveFabricFails -ge $maxConsecutiveFabricFails) {
              Write-Host ("  {0} consecutive Fabric failures. Stopping уровень {1}." -f $consecutiveFabricFails, $tier) -ForegroundColor Yellow
              break
            }
            continue
          }
          # * User closed the game during Fabric retry. No crash = batch is clean.
          if ($layerResult.Type -eq "UserExit") {
            Write-Host "  User closed the game during Fabric retry. Treating batch as clean." -ForegroundColor Yellow
            Update-McccHashCachePassedJar -JarNames $batchNames -Minecraft $mcVersionForLegacy
            $null = $remaining.RemoveRange(0, $actualBatchSize)
            $batchSize = $batchSize * 2
            Write-Host ("  Remaining: {0}" -f $remaining.Count) -ForegroundColor Green
            continue
          }
          # * Fall through to crash handling.
        }

        # * Crash handling: try basic algorithm, then binary isolation.
        if ($layerResult.Type -eq "Crash") {
          $phase = ("tier{0}_crash_identify" -f $tier)

          if ($mcVersionForLegacy -eq "unknown" -and $null -ne $layerResult.LogSnapshot) {
            $mcVersionForLegacy = Get-MinecraftVersionFromLog -Lines $layerResult.LogSnapshot.Lines
          }

          # * Step A: basic algorithm — read log, identify culprit.
          $logCulprits = @()
          if ($null -ne $layerResult.LogSnapshot) {
            $logCulprits = @(Find-CulpritFromLog -LogLines $layerResult.LogSnapshot.Lines -BatchMods $batch)
          }

          if ($logCulprits -and $logCulprits.Count -gt 0) {
            foreach ($cj in $logCulprits) {
              Write-Host ("  Log-identified culprit: {0}" -f $cj.Name) -ForegroundColor Green
              $logEvKey = if ($null -ne $layerResult.LogSnapshot) { Get-ErrorEvidenceKey -Lines $layerResult.LogSnapshot.Lines -MaxLines $ErrorSignatureLineLimit } else { "" }
              Move-CulpritToLegacy -JarName $cj.Name -EvidenceKey $logEvKey
            }
            # * Remove culprits from remaining, don't advance batchSize.
            $culpritNameSet = @{}
            foreach ($cj in $logCulprits) { $culpritNameSet[$cj.Name.ToLowerInvariant()] = $true }
            $newRemaining = [System.Collections.Generic.List[object]]::new()
            foreach ($m in $remaining) {
              if (-not $culpritNameSet.ContainsKey($m.Name.ToLowerInvariant())) {
                $newRemaining.Add($m)
              }
            }
            $remaining = $newRemaining
            # * Reset batch size after a culprit is found to re-probe carefully.
            $batchSize = 1
            continue
          }

          # * Tier-1 optimization: for deep crash diagnosis, keep only the current
          # * problematic batch active and park the rest of active tier-1 mods.
          $tier1NarrowingParkedJarNames = @()
          if ($tier -eq 1) {
            $tier1NarrowingParkedJarNames = @(Invoke-Tier1BatchNarrowing -BatchJarNames $batchNames)
          }

          # * Step B: binary isolation within the batch.
          if ($batch.Count -le 1) {
            # * Single mod batches can yield false positives when the crash persists for other reasons.
            # * Confirm by re-probing WITHOUT this mod before blaming it.
            $singleJarName = [string]$batch[0].Name
            Write-Host ("  Single mod batch crashed: {0}. Re-probing without it..." -f $singleJarName) -ForegroundColor Yellow

            $singleGamePath = Join-Path -Path $GameModsDir -ChildPath $singleJarName
            $singleStoragePath = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $singleJarName } else { $null }
            $singleGameDest = $null
            $singleStorageDest = $null
            if (Test-Path -LiteralPath $singleGamePath) {
              $singleGameDest = Move-ToQuarantine -SourcePath $singleGamePath -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
            }
            if ($useStorage -and $singleStoragePath -and (Test-Path -LiteralPath $singleStoragePath) -and $storageQuarantineDir) {
              $singleStorageDest = Move-ToQuarantine -SourcePath $singleStoragePath -DestDir $storageQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
            }
            if ($null -ne $singleGameDest -or $null -ne $singleStorageDest) {
              [void](Add-MovedItemRecord -JarName $singleJarName `
                  -GameSource $singleGamePath `
                  -GameQuarantine $singleGameDest `
                  -StorageSource $singleStoragePath `
                  -StorageQuarantine $singleStorageDest)
            }

            $phase = ("tier{0}_single_confirm" -f $tier)
            $confirmResult = Invoke-LayeringLaunchAndCheck -PhasePrefix ("tier{0}_single_confirm" -f $tier)
            if ($confirmResult.Type -eq "Success" -or $confirmResult.Type -eq "UserExit") {
              Write-Host ("  Confirmed culprit: {0}" -f $singleJarName) -ForegroundColor Green
              $singleEvKey = if ($null -ne $layerResult.LogSnapshot) { Get-ErrorEvidenceKey -Lines $layerResult.LogSnapshot.Lines -MaxLines $ErrorSignatureLineLimit } else { "" }
              Move-CulpritToLegacy -JarName $singleJarName -EvidenceKey $singleEvKey
              $null = $remaining.RemoveAt(0)
              $batchSize = 1
              if ($tier -eq 1 -and $tier1NarrowingParkedJarNames.Count -gt 0) {
                $tier1ProbeOk = Complete-Tier1BatchNarrowing `
                  -ParkedJarNames $tier1NarrowingParkedJarNames `
                  -RunConsistencyProbe $true `
                  -ProbePhasePrefix ("tier{0}_single_probe_restored" -f $tier)
                if (-not $tier1ProbeOk) {
                  $abortLayering = $true
                  $exitCode = 4
                  break
                }
              }
              continue
            }

            Write-Host ("  Re-probe still fails without {0}. Not blaming it; aborting layering." -f $singleJarName) -ForegroundColor Yellow

            # * Restore the mod back before abort to avoid partial state.
            $item = Get-MovedItemByJarName -JarName $singleJarName
            if ($null -ne $item -and $null -ne $item.GameQuarantine -and (Test-Path -LiteralPath $item.GameQuarantine)) {
              [void](Restore-FromQuarantine -SourcePath $item.GameQuarantine -DestDir $GameModsDir -IsDryRun $false -AllowOverwrite $true)
              $item.GameQuarantine = $null
            }
            if ($useStorage -and $null -ne $item -and $null -ne $item.StorageQuarantine -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
              [void](Restore-FromQuarantine -SourcePath $item.StorageQuarantine -DestDir $StorageModsDir -IsDryRun $false -AllowOverwrite $true)
              $item.StorageQuarantine = $null
            }
            if ($movedJarNameSet.ContainsKey($singleJarName)) {
              $null = $movedJarNameSet.Remove($singleJarName)
            }

            if ($tier -eq 1 -and $tier1NarrowingParkedJarNames.Count -gt 0) {
              [void](Complete-Tier1BatchNarrowing `
                  -ParkedJarNames $tier1NarrowingParkedJarNames `
                  -RunConsistencyProbe $false)
            }

            $abortLayering = $true
            $exitCode = 4
            break
          }

          Write-Host ("  Basic algorithm could not identify culprit. Running binary isolation on {0} mod(s)." -f $batch.Count) -ForegroundColor Cyan

          # * Capture crash signature as baseline for binary isolation.
          $crashSignature = ""
          $crashEvidenceKey = ""
          if ($null -ne $layerResult.LogSnapshot) {
            $crashSignature = Get-ErrorSignature -Lines $layerResult.LogSnapshot.Lines `
              -MaxLines $ErrorSignatureLineLimit `
              -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
            $crashEvidenceKey = Get-ErrorEvidenceKey -Lines $layerResult.LogSnapshot.Lines -MaxLines $ErrorSignatureLineLimit
          }

          # * Multi-culprit binary isolation loop.
          # * A single batch may contain several independently crashing mods.
          # * Binary search identifies one candidate at a time; after quarantining
          # * it, the search restarts on the reduced set until the crash is resolved.
          $batchForBinary = @($batch)
          $multiCulpritIteration = 0
          $multiCulpritMax = 32
          $binaryResolved = $false

          while ($batchForBinary.Count -gt 0 -and $multiCulpritIteration -lt $multiCulpritMax) {
            $multiCulpritIteration++

            # * PinnedJarNames = everything currently quarantined that is NOT in the binary batch.
            $binaryPinned = @($movedJarNameSet.Keys | Where-Object {
                $jarName = $_
                $inBatch = $false
                foreach ($bm in $batchForBinary) { if ($bm.Name -eq $jarName) { $inBatch = $true; break } }
                -not $inBatch
              })

            $phase = ("tier{0}_binary_isolation_{1}" -f $tier, $multiCulpritIteration)
            $binaryResult = Invoke-BinaryIsolation -Mods $batchForBinary `
              -BaselineSignature $crashSignature `
              -BaselineEvidenceKey $crashEvidenceKey `
              -PinnedJarNames $binaryPinned

            if ($binaryResult.Reason -eq "all_removed_no_change") {
              if ($multiCulpritIteration -eq 1) {
                # * First attempt: crash persists without ANY batch mods.
                Write-Host "  Crash persists without batch mods. Aborting layering." -ForegroundColor Yellow
                $abortLayering = $true
                $exitCode = 4
              } else {
                # * Subsequent attempt: remaining batch mods are clean.
                Write-Host ("  Remaining {0} batch mod(s) verified clean after removing {1} culprit(s)." -f $batchForBinary.Count, ($multiCulpritIteration - 1)) -ForegroundColor Green
                $binaryResolved = $true
              }
              break
            }

            $binaryRemaining = @($binaryResult.Remaining)
            if (-not $binaryRemaining -or $binaryRemaining.Count -eq 0) {
              Write-Host "  Binary isolation returned empty set. Skipping batch." -ForegroundColor Yellow
              break
            }

            foreach ($brMod in $binaryRemaining) {
              # * Quarantine this single mod and re-test.
              $gamePath = Join-Path -Path $GameModsDir -ChildPath $brMod.Name
              if (Test-Path -LiteralPath $gamePath) {
                $dest = Move-ToQuarantine -SourcePath $gamePath -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
                if ($null -ne $dest) {
                  [void](Add-MovedItemRecord -JarName $brMod.Name -GameSource $gamePath -GameQuarantine $dest -StorageSource $null -StorageQuarantine $null)
                }
              }

              $phase = ("tier{0}_binary_linear_check_{1}" -f $tier, $multiCulpritIteration)
              $linearResult = Invoke-LayeringLaunchAndCheck -PhasePrefix ("tier{0}_binary_linear_{1}" -f $tier, $multiCulpritIteration)

              if ($linearResult.Type -eq "Success" -or $linearResult.Type -eq "UserExit") {
                # * Removing this mod fixed it — it's the (last) culprit.
                Write-Host ("  Binary isolation culprit: {0}" -f $brMod.Name) -ForegroundColor Green
                Move-CulpritToLegacy -JarName $brMod.Name -EvidenceKey $crashEvidenceKey
                $binaryResolved = $true
                break
              } else {
                # * Still crashes — this mod is one of multiple culprits.
                # * Keep it quarantined and search for more.
                Write-Host ("  Multi-culprit: {0} (crash persists; searching for more)" -f $brMod.Name) -ForegroundColor Yellow
                Move-CulpritToLegacy -JarName $brMod.Name -EvidenceKey $crashEvidenceKey
                # * Track this mod as quarantined so it stays pinned in the next iteration.
                $movedJarNameSet[$brMod.Name] = $true
                $batchForBinary = @($batchForBinary | Where-Object { $_.Name -ne $brMod.Name })

                # * Update baseline crash signature for the next iteration.
                # * The remaining crash may have a different root cause now.
                if ($null -ne $linearResult.LogSnapshot) {
                  $crashSignature = Get-ErrorSignature -Lines $linearResult.LogSnapshot.Lines `
                    -MaxLines $ErrorSignatureLineLimit `
                    -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
                  $crashEvidenceKey = Get-ErrorEvidenceKey -Lines $linearResult.LogSnapshot.Lines -MaxLines $ErrorSignatureLineLimit
                }
                break
              }
            }

            if ($binaryResolved) { break }
          }

          if ($abortLayering) {
            if ($tier -eq 1 -and $tier1NarrowingParkedJarNames.Count -gt 0) {
              [void](Complete-Tier1BatchNarrowing `
                  -ParkedJarNames $tier1NarrowingParkedJarNames `
                  -RunConsistencyProbe $false)
            }
            break
          }

          # * Post-resolution: update remaining list and hash cache.
          if ($binaryResolved -or $batchForBinary.Count -eq 0) {
            # * Batch fully processed: culprit(s) quarantined, rest verified clean.
            $cleanBatchNames = @($batch | ForEach-Object { $_.Name } | Where-Object {
                -not $culpritJarNames.Contains($_)
              })
            if ($cleanBatchNames.Count -gt 0) {
              Update-McccHashCachePassedJar -JarNames $cleanBatchNames -Minecraft $mcVersionForLegacy
            }
            $null = $remaining.RemoveRange(0, $actualBatchSize)
          } else {
            # * Could not fully resolve the batch. Remove found culprits from remaining.
            $culpritNameSet = @{}
            foreach ($cn in $culpritJarNames) { $culpritNameSet[$cn.ToLowerInvariant()] = $true }
            $newRemaining = [System.Collections.Generic.List[object]]::new()
            foreach ($m in $remaining) {
              if (-not $culpritNameSet.ContainsKey($m.Name.ToLowerInvariant())) {
                $newRemaining.Add($m)
              }
            }
            $remaining = $newRemaining
          }
          $batchSize = 1
          if ($tier -eq 1 -and $tier1NarrowingParkedJarNames.Count -gt 0) {
            $needTier1Probe = ($binaryResolved -or $batchForBinary.Count -eq 0)
            $tier1ProbeOk = Complete-Tier1BatchNarrowing `
              -ParkedJarNames $tier1NarrowingParkedJarNames `
              -RunConsistencyProbe $needTier1Probe `
              -ProbePhasePrefix ("tier{0}_binary_probe_restored" -f $tier)
            if (-not $tier1ProbeOk) {
              $abortLayering = $true
              $exitCode = 4
              break
            }
          }
          continue
        }

        # * Unexpected outcome — stop уровень.
        Write-Host ("  Unexpected outcome: {0}. Stopping уровень." -f $layerResult.Type) -ForegroundColor Yellow
        break
      }

      if ($abortLayering) { break }
    }
  }

} catch [System.OperationCanceledException] {
  $hadError = $true
  $cancelMessage = [string]$_.Exception.Message
  if ($cancelMessage -match "^MCCompatUserCancelKeepChanges:") {
    $KeepMovedModsOnFailure = $true
    Write-Host "Launch canceled by user. Keeping current layering state." -ForegroundColor Yellow
  } else {
    Write-Host "Launch canceled by user. Rolling back layering changes." -ForegroundColor Yellow
  }
  $exitCode = 130
} catch [System.Management.Automation.PipelineStoppedException] {
  # * User pressed Ctrl+C. Restore all mods; skip error dump.
  # * Write-Host during PipelineStoppedException may not appear in the transcript.
  # * The user-facing message is emitted from the finally block instead.
  $hadError = $true
  $wasCtrlC = $true
  $exitCode = 1
} catch {
  $hadError = $true
  $dumpDir = $gameQuarantineDir
  if ([string]::IsNullOrWhiteSpace($dumpDir)) {
    $dumpDir = Join-Path -Path $GameModsDir -ChildPath "legacy\\temp"
  }
  $dumpPath = Write-ErrorDump -TargetDir $dumpDir -Phase $phase -ErrorRecord $_
  if ($dumpPath) {
    Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Error dump: {0}" -f $dumpPath) -ForegroundColor Gray
  } else {
    Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
  }
  Write-Host ("Phase: {0}" -f $phase) -ForegroundColor Gray
  $exitCode = 1
} finally {
  if ($wasCtrlC) {
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Layering interrupted by user (Ctrl+C). Restoring mods..." -ForegroundColor Yellow
    Write-Host ("Phase at interruption: {0}" -f $phase) -ForegroundColor Gray
  }
  if (-not $DryRun) {
    # * Ensure the game is closed before restore/exit.
    [void](Stop-ConfiguredGameProcess -StartedAfter $layeringStartTime)
    [void](Wait-ConfiguredGameExit -StartedAfter $layeringStartTime -WarningContext "Layering cleanup")
  }
  # * Restore all quarantined mods (except culprits).
  if ($movedItems.Count -gt 0) {
    if ($hadError -and $KeepMovedModsOnFailure) {
      Write-Host "Keeping moved mods due to failure." -ForegroundColor Yellow
    } else {
      $excludeSet = @{}
      if (-not $hadError) {
        foreach ($name in $culpritJarNames) {
          if (-not [string]::IsNullOrWhiteSpace($name)) { $excludeSet[$name] = $true }
        }
      }
      $restoreCount = 0
      foreach ($item in $movedItems) {
        if ($excludeSet.Count -gt 0 -and $excludeSet.ContainsKey($item.JarName)) { continue }
        if (-not [string]::IsNullOrWhiteSpace($item.GameQuarantine) -and (Test-Path -LiteralPath $item.GameQuarantine)) {
          $restoreGame = Restore-FromQuarantine -SourcePath $item.GameQuarantine -DestDir $GameModsDir -IsDryRun $false -AllowOverwrite ([bool]$ForceRestore)
          if ($restoreGame) { $restoreCount++ }
        }
        if ($useStorage -and -not [string]::IsNullOrWhiteSpace($item.StorageQuarantine) -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
          [void](Restore-FromQuarantine -SourcePath $item.StorageQuarantine -DestDir $StorageModsDir -IsDryRun $false -AllowOverwrite ([bool]$ForceRestore))
        }
      }
      if ($restoreCount -gt 0) {
        Write-Host ("Restored {0} mod(s) from quarantine." -f $restoreCount) -ForegroundColor Green
      }
    }
  }

  # * Move culprits to permanent legacy.
  if (-not $hadError -and $culpritJarNames.Count -gt 0) {
    $storageLegacyVersionDir = $null
    if ($useStorage) {
      $storageLegacyRoot = Join-Path -Path $StorageModsDir -ChildPath $StorageLegacyFolderName
      $storageLegacyVersionDir = Join-Path -Path $storageLegacyRoot -ChildPath $mcVersionForLegacy
      New-DirectoryIfMissing -DirPath $storageLegacyVersionDir
    }

    $keepGameLegacyEffective = [bool]$KeepCulpritInGameLegacy
    if (-not $useStorage -and (-not $keepGameLegacyEffective)) {
      Write-Host "Warning: storage is disabled; keeping culprit in game legacy." -ForegroundColor Yellow
      $keepGameLegacyEffective = $true
    }

    $gameLegacyVersionDir = $null
    if ($keepGameLegacyEffective) {
      $gameLegacyRoot2 = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
      $gameLegacyVersionDir = Join-Path -Path $gameLegacyRoot2 -ChildPath $mcVersionForLegacy
      New-DirectoryIfMissing -DirPath $gameLegacyVersionDir
    }

    foreach ($culpritName in $culpritJarNames) {
      if ([string]::IsNullOrWhiteSpace($culpritName)) { continue }

      $culpritStorageLegacyPath = $null
      $culpritGameLegacyPath = $null

      # * Move quarantined copy to storage legacy.
      if ($useStorage) {
        foreach ($item in $movedItems) {
          if ($item.JarName -ne $culpritName) { continue }
          if ($null -ne $item.StorageQuarantine -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
            $destPath = Join-Path -Path $storageLegacyVersionDir -ChildPath $culpritName
            Move-Item -LiteralPath $item.StorageQuarantine -Destination $destPath -Force -ErrorAction Stop
            Write-Host ("Moved culprit to storage legacy: {0}" -f $destPath) -ForegroundColor Green
            # * Append to persistent legacy.log.
            $legacyLogEntry = "Moved culprit to storage legacy: {0}" -f $destPath
            Add-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "legacy.log") -Value $legacyLogEntry -ErrorAction SilentlyContinue
            $culpritStorageLegacyPath = $destPath
            break
          }
        }
      }

      # * Move quarantined copy to game legacy (or remove game copy).
      if ($keepGameLegacyEffective) {
        foreach ($item in $movedItems) {
          if ($item.JarName -ne $culpritName) { continue }
          if ($null -ne $item.GameQuarantine -and (Test-Path -LiteralPath $item.GameQuarantine)) {
            $destPath = Join-Path -Path $gameLegacyVersionDir -ChildPath $culpritName
            Move-Item -LiteralPath $item.GameQuarantine -Destination $destPath -Force -ErrorAction Stop
            Write-Host ("Moved culprit to game legacy: {0}" -f $destPath) -ForegroundColor Green
            $culpritGameLegacyPath = $destPath
            break
          }
        }
      } else {
        foreach ($item in $movedItems) {
          if ($item.JarName -ne $culpritName) { continue }
          if ($null -ne $item.GameQuarantine -and (Test-Path -LiteralPath $item.GameQuarantine)) {
            Remove-Item -LiteralPath $item.GameQuarantine -Force -ErrorAction Stop
            break
          }
        }
      }

      $evKey = if ($culpritEvidenceKeys.ContainsKey($culpritName)) { $culpritEvidenceKeys[$culpritName] } else { "" }
      $culpritMoves.Add([pscustomobject]@{
          JarName = $culpritName
          GameModsDir = $GameModsDir
          StorageModsDir = if ($useStorage) { $StorageModsDir } else { "" }
          StorageLegacyPath = $culpritStorageLegacyPath
          GameLegacyPath = $culpritGameLegacyPath
          Minecraft = $mcVersionForLegacy
          KeepCulpritInGameLegacy = [bool]$keepGameLegacyEffective
          CrashEvidenceKey = $evKey
          Stage = "layering"
        })
    }
  }
}

# ────────────────────────────────────────────────────────────────────────────
# * Summary.
# ────────────────────────────────────────────────────────────────────────────

if ($culpritJarNames.Count -gt 0) {
  Write-Host ("Layering complete. Culprit(s): {0}" -f (($culpritJarNames | Sort-Object -Unique) -join ", ")) -ForegroundColor Green
  if (-not $hadError -and $exitCode -eq 4) {
    Write-Host "Layering aborted early: crash persisted after single-mod re-probe; falling back to isolation is recommended." -ForegroundColor Yellow
  }
} elseif (-not $hadError -and $exitCode -eq 0 -and $hadUnresolvableFabric) {
  Write-Host "Layering incomplete: some batches had unresolvable Fabric dependencies." -ForegroundColor Yellow
  $exitCode = 3
} elseif (-not $hadError -and $exitCode -eq 4) {
  Write-Host "Layering aborted early: crash persisted after single-mod re-probe; falling back to isolation is recommended." -ForegroundColor Yellow
} elseif (-not $hadError -and $exitCode -eq 0) {
  Write-Host "Layering complete. All mods layered successfully — no culprit found." -ForegroundColor Green
} elseif ($exitCode -eq 2) {
  Write-Host "Layering aborted: core libraries (уровень 4) could not launch." -ForegroundColor Yellow
}

if ($EmitResultObject) {
  Write-Output ([pscustomobject]@{
      Type = "LayeringResult"
      RunId = $runId
      GameModsDir = $GameModsDir
      StorageModsDir = if ($useStorage) { $StorageModsDir } else { "" }
      Minecraft = $mcVersionForLegacy
      HashCacheEnabled = [bool]$script:mcccCacheEnabled
      HashCachePath = $script:mcccCachePath
      HashCacheSkippedJarNames = @($script:mcccKnownGoodJarNameSet.Keys | Sort-Object)
      CulpritJarNames = @($culpritJarNames | Sort-Object -Unique)
      CulpritMoves = @($culpritMoves.ToArray())
      ExitCode = $exitCode
    })
}

exit $exitCode
