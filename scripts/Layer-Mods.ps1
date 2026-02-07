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

$sharedLegacyPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Legacy.ps1"
if (-not (Test-Path -LiteralPath $sharedLegacyPath)) { throw ("Shared legacy helpers not found: {0}" -f $sharedLegacyPath) }
. $sharedLegacyPath

$sharedStageResultPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-StageResult.ps1"
if (-not (Test-Path -LiteralPath $sharedStageResultPath)) { throw ("Shared stage result helpers not found: {0}" -f $sharedStageResultPath) }
. $sharedStageResultPath

$sharedIsolationDecisionsPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Decisions.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationDecisionsPath)) { throw ("Shared isolation decision helpers not found: {0}" -f $sharedIsolationDecisionsPath) }
. $sharedIsolationDecisionsPath

$layerBaselinePath = Join-Path -Path $PSScriptRoot -ChildPath "Layer-Mods.Baseline.ps1"
if (-not (Test-Path -LiteralPath $layerBaselinePath)) { throw ("Layering baseline script not found: {0}" -f $layerBaselinePath) }

$layerExecutionPath = Join-Path -Path $PSScriptRoot -ChildPath "Layer-Mods.Execution.ps1"
if (-not (Test-Path -LiteralPath $layerExecutionPath)) { throw ("Layering execution script not found: {0}" -f $layerExecutionPath) }

$layerBatchTriagePath = Join-Path -Path $PSScriptRoot -ChildPath "Layer-Mods.BatchTriage.ps1"
if (-not (Test-Path -LiteralPath $layerBatchTriagePath)) { throw ("Layering batch triage script not found: {0}" -f $layerBatchTriagePath) }

$layerFinalizePath = Join-Path -Path $PSScriptRoot -ChildPath "Layer-Mods.Finalize.ps1"
if (-not (Test-Path -LiteralPath $layerFinalizePath)) { throw ("Layering finalize script not found: {0}" -f $layerFinalizePath) }

# ────────────────────────────────────────────────────────────────────────────
# * Config.
# ────────────────────────────────────────────────────────────────────────────

$runtimeConfig = Initialize-McccRuntimeConfig `
  -StartDir $PSScriptRoot `
  -BoundParameters $PSBoundParameters `
  -GameModsDir $GameModsDir `
  -StorageModsDir $StorageModsDir `
  -LogPath $LogPath `
  -LauncherExePath $LauncherExePath `
  -AlwaysDefaultGameModsDir $false `
  -DefaultStorageToGame $false
$GameModsDir = $runtimeConfig.Paths.GameModsDir
$StorageModsDir = $runtimeConfig.Paths.StorageModsDir
$LogPath = $runtimeConfig.Paths.LogPath
$LauncherExePath = $runtimeConfig.Paths.LauncherExePath
$useStorage = $runtimeConfig.Paths.UseStorage

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
  . $layerBaselinePath
  . $layerExecutionPath

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
  . $layerFinalizePath
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
  $stageResultParams = @{
    Stage = "Layering"
    Type = "LayeringResult"
    RunId = $runId
    GameModsDir = $GameModsDir
    StorageModsDir = if ($useStorage) { $StorageModsDir } else { "" }
    Minecraft = $mcVersionForLegacy
    ExitCode = $exitCode
    CulpritJarNames = @($culpritJarNames | Sort-Object -Unique)
    CulpritMoves = @($culpritMoves.ToArray())
    HashCacheEnabled = [bool]$script:mcccCacheEnabled
    HashCachePath = $script:mcccCachePath
    HashCacheSkippedJarNames = @($script:mcccKnownGoodJarNameSet.Keys | Sort-Object)
  }
  Write-Output (New-StageResult @stageResultParams)
}

exit $exitCode
