<#
.SYNOPSIS
Isolates a crashing mod by moving jars to Legacy (binary or linear).

.DESCRIPTION
Moves mods from GameModsDir into a per-run Legacy\temp quarantine, using either:
  - binary halving (default), or
  - linear one-by-one (UseLinearIsolation),
launches the game each time, and stops when either:
  - the launch succeeds (no crash dialog within the timeout), or
  - the error signature from logs changes compared to the baseline.
After stopping, all moved mods are restored except the last removed one.
This script does NOT rely on mod IDs from logs, so it still works if the log points to
an internal module or library id.

.PARAMETER GameModsDir
Active mods folder used by the launcher/game.

.PARAMETER GameLegacyFolderName
Folder name inside GameModsDir used to store quarantined mods (uses Legacy\temp).

.PARAMETER StorageModsDir
Optional storage mods folder. If empty, storage operations are skipped.

.PARAMETER StorageLegacyFolderName
Folder name inside StorageModsDir used to store quarantined mods (uses Legacy\temp).

.PARAMETER LogPath
Optional log path to use as primary log. Leave empty to auto-pick the latest tl-logger*.txt.

.PARAMETER LogMaxAgeMinutes
Maximum age (minutes) for additional game logs (latest.log, debug.log, crash reports).
Set to 0 to disable age filtering.

.PARAMETER SkipGameLogs
If set, skips scanning game logs when LogPath is empty.

.PARAMETER LogReadRetryCount
Retry count when reading a log that may still be writing.

.PARAMETER LogReadRetryDelayMs
Delay between log read retries.

.PARAMETER LogPostRunDelaySeconds
Delay after a launch attempt to let logs flush.

.PARAMETER WaitForGameExitSeconds
Maximum seconds to wait for game JVM/processes (spawned by the attempt) to exit after a crash.

.PARAMETER GameProcessNames
Process names to wait for (without .exe). Used together with WaitForGameExitSeconds.

.PARAMETER GameExitPollSeconds
Polling interval (seconds) while waiting for game processes to exit.

.PARAMETER MoveRetryCount
How many times to retry moving a mod jar if the file is locked.

.PARAMETER MoveRetryDelayMs
Delay between move retries (milliseconds).

.PARAMETER SkipBaselineRun
If set, uses current logs as the baseline without launching.

.PARAMETER ErrorSignatureLineLimit
Number of error lines to include in the signature.

.PARAMETER IncludeWarnMixinsAsIncompatible
If set, also matches WARN mixin lines in the signature.

.PARAMETER IgnoreModListForSignatureChange
If true (default), signature change detection prefers comparing selected error evidence lines (when present)
and ignores changes in the extracted mod ID list. This avoids false positives caused by dependency cascades
that change Fabric's incompatible mod listing without changing the underlying error.

.PARAMETER PreIsolateJarNames
Optional list of jar file names to move into the quarantine AFTER the baseline is captured and BEFORE the iterative loop.
This "fast-forward" reduces repeated re-testing when isolation is triggered multiple times in the same Auto-Run session.

.PARAMETER PreIsolateBaselineEvidenceKey
Optional baseline evidence key from the previous isolation activation.
If set, PreIsolateJarNames is only applied when the current baseline evidence key matches this value.
This prevents stale fast-forward lists from being applied after the underlying crash changes.

.PARAMETER EmitResultObject
If set, writes a single structured object to the pipeline with details about the isolation run
(including a suggested fast-forward jar list for the next activation).

.PARAMETER LauncherExePath
Optional path to Legacy Launcher executable. If empty, attaches to a running launcher window.

.PARAMETER LauncherArguments
Additional launcher CLI arguments.

.PARAMETER UseAutoLaunch
If set, appends --launch to enable auto-start.

.PARAMETER LauncherWindowTitlePattern
Partial title of the launcher main window.

.PARAMETER PlayButtonNames
Button names to start the game. Add localized names if needed.

.PARAMETER PlayClickOffsetX
Optional click offset (pixels) relative to the top-left of the launcher window.

.PARAMETER PlayClickOffsetY
Optional click offset (pixels) relative to the top-left of the launcher window.

.PARAMETER PlayClickDelayMs
Delay (milliseconds) after focusing the launcher window and before clicking Play.
Helps when the launcher ignores immediate clicks due to focus/animation timing.

.PARAMETER LaunchStartTimeoutSeconds
Seconds to wait after triggering Play to detect that the game actually starts (a game process starts or the launcher window closes).
If exceeded, Play triggering is retried to avoid false "success" timeouts when the click does nothing.

.PARAMETER PlayClickMaxAttempts
How many times to attempt triggering Play per launch attempt when no game start is detected.

.PARAMETER RequireGameStartForTimeout
If true (default), a Timeout outcome is only treated as success when a game start is detected.

.PARAMETER UseLinearIsolation
If set, uses the legacy linear isolation (one mod per attempt) instead of exponential probing with binary refinement.

.PARAMETER BinaryLinearThreshold
When binary refinement is active, falls back to linear once the remaining candidate set is at or below this size.

.PARAMETER UseEnterFallback
If true, sends ENTER when play element is not found.

.PARAMETER EnableBroadUiSearch
If true, enables a broad UI Automation fallback search which can be slow on some launcher builds.
Disabled by default to avoid hangs; prefer -PlayClickOffsetX/-PlayClickOffsetY or Enter fallback.

.PARAMETER PrintCursorOffset
If set, captures current mouse offsets relative to the launcher window and prints them.
If PlayClickOffsetX/Y are not set, uses the captured offsets for click.

.PARAMETER CrashWindowTitlePatterns
Crash dialog title fragments.

.PARAMETER FabricWindowTitlePatterns
Fabric or dependency dialog title fragments.

.PARAMETER CrashCloseClickOffsetX
Optional click offset for closing crash dialog (relative to crash window).

.PARAMETER CrashCloseClickOffsetY
Optional click offset for closing crash dialog (relative to crash window).

.PARAMETER CrashCloseDelaySeconds
Delay before closing crash dialog automatically.

.PARAMETER LauncherWindowTimeoutSeconds
Wait time to find launcher window after start.

.PARAMETER OutcomeTimeoutSeconds
Time window to detect outcomes after clicking Play.

.PARAMETER PollIntervalSeconds
Polling interval.

.PARAMETER MaxModsToTest
Limits how many mods are tested (newest first). Use 0 to test all.

.PARAMETER ExcludeJarNames
Array of jar file names to skip.

.PARAMETER NoCache
If set, disables the session launch-configuration cache and always re-runs launch checks.

.PARAMETER ForceRestore
If set, overwrites existing jars when restoring.

.PARAMETER KeepMovedModsOnFailure
If set, does not restore moved mods on unexpected errors.

.PARAMETER DryRun
If set, only prints the planned order and exits without changes.

.PARAMETER Help
Show detailed help for this script and exit.

.EXAMPLE
.\Isolate-Incompatible-Mod.ps1 -LauncherExePath "C:\Path\LegacyLauncher.exe" -UseAutoLaunch

.EXAMPLE
.\Isolate-Incompatible-Mod.ps1 -SkipBaselineRun -PlayClickOffsetX 210 -PlayClickOffsetY 440
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  # * Active mods folder used by the launcher/game.
  [Parameter(Mandatory = $false)]
  [string]$GameModsDir = "",

  # * Folder name inside GameModsDir used to store quarantined mods.
  [Parameter(Mandatory = $false)]
  [string]$GameLegacyFolderName = "legacy",

  # * Optional storage mods folder. If empty, storage operations are skipped.
  [Parameter(Mandatory = $false)]
  [string]$StorageModsDir = "",

  # * Folder name inside StorageModsDir used to store quarantined mods.
  [Parameter(Mandatory = $false)]
  [string]$StorageLegacyFolderName = "Legacy",

  # * If set, keeps the culprit jar in game legacy folder too.
  # * Without this flag, the culprit is removed from the game side and only stored in Storage legacy (when available).
  [Parameter(Mandatory = $false)]
  [switch]$KeepCulpritInGameLegacy,

  # * Optional log path to use as primary log.
  [Parameter(Mandatory = $false)]
  [string]$LogPath = "",

  # * Maximum age (minutes) for additional game logs (latest.log, crash reports).
  [Parameter(Mandatory = $false)]
  [int]$LogMaxAgeMinutes = 30,

  # * If set, skips scanning game logs (latest.log, crash reports).
  [Parameter(Mandatory = $false)]
  [switch]$SkipGameLogs,

  # * Retry count when reading a log that may still be writing.
  [Parameter(Mandatory = $false)]
  [int]$LogReadRetryCount = 5,

  # * Delay between log read retries.
  [Parameter(Mandatory = $false)]
  [int]$LogReadRetryDelayMs = 500,

  # * Delay after launch attempt to let logs flush.
  [Parameter(Mandatory = $false)]
  [int]$LogPostRunDelaySeconds = 3,

  # * Maximum seconds to wait for game processes spawned by the attempt to exit after a crash.
  [Parameter(Mandatory = $false)]
  [int]$WaitForGameExitSeconds = 30,

  # * Process names to wait for (without .exe).
  [Parameter(Mandatory = $false)]
  [string[]]$GameProcessNames = @("javaw", "java", "Minecraft"),

  # * Polling interval (seconds) while waiting for game processes to exit.
  [Parameter(Mandatory = $false)]
  [int]$GameExitPollSeconds = 2,

  # * If set, uses current logs as the baseline without launching.
  [Parameter(Mandatory = $false)]
  [switch]$SkipBaselineRun,

  # * Number of error lines to include in the signature.
  [Parameter(Mandatory = $false)]
  [int]$ErrorSignatureLineLimit = 2,

  # * If set, also matches WARN mixin lines in the signature.
  [Parameter(Mandatory = $false)]
  [switch]$IncludeWarnMixinsAsIncompatible,

  # * If true, signature-change detection prefers evidence lines when present.
  # * This avoids false positives when mod ID lists change due to dependency cascades.
  [Parameter(Mandatory = $false)]
  [bool]$IgnoreModListForSignatureChange = $true,

  # * Optional path to Legacy Launcher executable. If empty, attaches to a running launcher window.
  [Parameter(Mandatory = $false)]
  [string]$LauncherExePath = "",

  # * Additional launcher CLI arguments.
  [Parameter(Mandatory = $false)]
  [string[]]$LauncherArguments = @(),

  # * If set, appends --launch to enable auto-start.
  [Parameter(Mandatory = $false)]
  [Alias("Auto")]
  [switch]$UseAutoLaunch,

  # * Partial title of the launcher main window.
  [Parameter(Mandatory = $false)]
  [string]$LauncherWindowTitlePattern = "Legacy Launcher",

  # * Button names to start the game.
  [Parameter(Mandatory = $false)]
  [string[]]$PlayButtonNames = @("Запустить", "Play", "Start"),

  # * Optional click offsets (pixels) relative to the top-left of the launcher window.
  # * Set both to enable coordinate-based click fallback.
  [Parameter(Mandatory = $false)]
  [int]$PlayClickOffsetX = -1,

  # * Optional click offsets (pixels) relative to the top-left of the launcher window.
  # * Set both to enable coordinate-based click fallback.
  [Parameter(Mandatory = $false)]
  [int]$PlayClickOffsetY = -1,

  # * Delay (ms) after focusing launcher and before clicking Play.
  [Parameter(Mandatory = $false)]
  [int]$PlayClickDelayMs = 1000,

  # * How long to wait (s) after triggering Play to detect game start.
  [Parameter(Mandatory = $false)]
  [int]$LaunchStartTimeoutSeconds = 15,

  # * How many times to try triggering Play when no game start is detected.
  [Parameter(Mandatory = $false)]
  [int]$PlayClickMaxAttempts = 2,

  # * If true, only treat Timeout as success if game start is detected.
  [Parameter(Mandatory = $false)]
  [bool]$RequireGameStartForTimeout = $true,

  # * If set, uses linear isolation instead of exponential probing.
  [Parameter(Mandatory = $false)]
  [switch]$UseLinearIsolation,

  # * When binary refinement is active, switch to linear at or below this count.
  [Parameter(Mandatory = $false)]
  [int]$BinaryLinearThreshold = 8,

  # * If true, sends ENTER when play element is not found.
  [Parameter(Mandatory = $false)]
  [bool]$UseEnterFallback = $true,

  # * Enables a broad UI Automation fallback search (can be slow).
  [Parameter(Mandatory = $false)]
  [bool]$EnableBroadUiSearch = $false,

  # * If set, prints current mouse offsets relative to the launcher window and uses them for click.
  [Parameter(Mandatory = $false)]
  [switch]$PrintCursorOffset,

  # * Crash dialog title fragments.
  [Parameter(Mandatory = $false)]
  [string[]]$CrashWindowTitlePatterns = @("Что-то сломалось"),

  # * Fabric or dependency dialog title fragments.
  [Parameter(Mandatory = $false)]
  [string[]]$FabricWindowTitlePatterns = @("Fabric Loader", "owo-sentinel"),

  # * Optional click offsets for closing crash dialog (relative to crash window).
  [Parameter(Mandatory = $false)]
  [int]$CrashCloseClickOffsetX = -1,

  # * Optional click offsets for closing crash dialog (relative to crash window).
  [Parameter(Mandatory = $false)]
  [int]$CrashCloseClickOffsetY = -1,

  # * Delay before closing crash dialog automatically.
  [Parameter(Mandatory = $false)]
  [int]$CrashCloseDelaySeconds = 5,

  # * Wait time to find launcher window after start.
  [Parameter(Mandatory = $false)]
  [int]$LauncherWindowTimeoutSeconds = 60,

  # * Time window to detect outcomes after clicking Play.
  [Parameter(Mandatory = $false)]
  [int]$OutcomeTimeoutSeconds = 60,

  # * Polling interval.
  [Parameter(Mandatory = $false)]
  [int]$PollIntervalSeconds = 2,

  # * Limits how many mods are tested (newest first). Use 0 to test all.
  [Parameter(Mandatory = $false)]
  [int]$MaxModsToTest = 0,

  # * If true, orders candidates by "library importance" before testing.
  # * Importance is estimated by how many other mods depend on this mod (incoming edges in the JAR dependency graph).
  # * Low-dependency mods are isolated first to avoid dependency-cascade false positives.
  [Parameter(Mandatory = $false)]
  [bool]$UseDependencyAwareOrdering = $true,

  # * Dependency graph counting mode.
  # * - RequiredOnly: counts only required dependencies (Fabric/Quilt depends, Forge/NeoForge mandatory=true).
  # * - All: counts all dependency references (including suggests/recommends/conflicts).
  [Parameter(Mandatory = $false)]
  [ValidateSet("RequiredOnly", "All")]
  [string]$DependencyAwareOrderingCountMode = "RequiredOnly",

  # * Tier thresholds for dependent-mod counts (inclusive).
  # * Tier 1: 0 dependents
  # * Tier 2: <= DependencyAwareTier2MaxDependents
  # * Tier 3: <= DependencyAwareTier3MaxDependents
  # * Tier 4: > DependencyAwareTier3MaxDependents (core libraries)
  [Parameter(Mandatory = $false)]
  [int]$DependencyAwareTier2MaxDependents = 3,

  [Parameter(Mandatory = $false)]
  [int]$DependencyAwareTier3MaxDependents = 10,

  # * If true, jars with unreadable/unknown metadata are treated as core libraries (isolated last).
  [Parameter(Mandatory = $false)]
  [bool]$DependencyAwareTreatUnknownAsCore = $true,

  # * If true, dependency-aware ordering forces linear isolation (disables hybrid).
  [Parameter(Mandatory = $false)]
  [bool]$DependencyAwareForceLinearIsolation = $false,

  # * Highest dependency-aware tier that still uses exponential/binary (0 disables).
  [Parameter(Mandatory = $false)]
  [int]$DependencyAwareExponentialMaxTier = 2,

  # * Max dependency-aware tier allowed for quick-isolate (0 disables tier filter).
  [Parameter(Mandatory = $false)]
  [int]$DependencyAwareQuickIsolateMaxTier = 3,

  # * If true, abort isolation when the baseline run hits dependency dialogs.
  [Parameter(Mandatory = $false)]
  [bool]$RespectDependencyDialogsInBaseline = $true,

  # * Dependency map source for dependency-aware ordering and mod ID resolution.
  # * - Tool: runs tools\Analyze-JarDependencyMap.ps1 and loads jar-dependency-map.json.
  # * - File: loads dependency map JSON from DependencyMapJsonPath.
  # * - Internal: parses jars inside this script (legacy fallback).
  [Parameter(Mandatory = $false)]
  [ValidateSet("Tool", "File", "Internal")]
  [string]$DependencyMapSource = "Tool",

  # * Dependency map JSON path when DependencyMapSource=File (optional).
  [Parameter(Mandatory = $false)]
  [string]$DependencyMapJsonPath = "",

  # * Path to Analyze-JarDependencyMap.ps1 when DependencyMapSource=Tool (optional).
  [Parameter(Mandatory = $false)]
  [string]$DependencyMapToolPath = "",

  # * Output directory for dependency map tool reports (optional).
  [Parameter(Mandatory = $false)]
  [string]$DependencyMapOutDir = "",

  # * Array of jar file names to skip.
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

  # * Optional jar file names to quarantine after baseline (fast-forward resume).
  [Parameter(Mandatory = $false)]
  [string[]]$PreIsolateJarNames = @(),

  # * If set, apply fast-forward only when the baseline evidence key matches.
  [Parameter(Mandatory = $false)]
  [string]$PreIsolateBaselineEvidenceKey = "",

  # * If set, emits a single structured object to the pipeline with run details.
  [Parameter(Mandatory = $false)]
  [switch]$EmitResultObject,

  # * How many times to retry moving a jar if locked.
  [Parameter(Mandatory = $false)]
  [int]$MoveRetryCount = 15,

  # * Delay between move retries (milliseconds).
  [Parameter(Mandatory = $false)]
  [int]$MoveRetryDelayMs = 1000,

  # * If set, overwrites existing jars when restoring.
  [Parameter(Mandatory = $false)]
  [switch]$ForceRestore,

  # * If set, does not restore moved mods on unexpected errors.
  [Parameter(Mandatory = $false)]
  [switch]$KeepMovedModsOnFailure,

  # * If set, only prints the planned order and exits without changes.
  [Parameter(Mandatory = $false)]
  [switch]$DryRun,

  # * Show detailed help and exit.
  [Parameter(Mandatory = $false)]
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Help) {
  Get-Help -Full -Name $PSCommandPath
  return
}

# * Load shared helpers.
$sharedUiPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LauncherUi.ps1"
if (-not (Test-Path -LiteralPath $sharedUiPath)) {
  throw ("Shared UI helpers not found: {0}" -f $sharedUiPath)
}
. $sharedUiPath

$sharedLogPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LogTools.ps1"
if (-not (Test-Path -LiteralPath $sharedLogPath)) {
  throw ("Shared log helpers not found: {0}" -f $sharedLogPath)
}
. $sharedLogPath

# * Load shared config helpers.
$sharedConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Config.ps1"
if (-not (Test-Path -LiteralPath $sharedConfigPath)) {
  throw ("Shared config helpers not found: {0}" -f $sharedConfigPath)
}
. $sharedConfigPath

# * Load isolation helpers.
$sharedIsolationLauncherPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Launcher.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationLauncherPath)) {
  throw ("Shared isolation launcher helpers not found: {0}" -f $sharedIsolationLauncherPath)
}
. $sharedIsolationLauncherPath

$sharedIsolationLogPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-LogParsing.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationLogPath)) {
  throw ("Shared isolation log helpers not found: {0}" -f $sharedIsolationLogPath)
}
. $sharedIsolationLogPath

$sharedIsolationJarDepPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-JarDependencies.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationJarDepPath)) {
  throw ("Shared isolation jar dependency helpers not found: {0}" -f $sharedIsolationJarDepPath)
}
. $sharedIsolationJarDepPath

$sharedIsolationQuarantinePath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Quarantine.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationQuarantinePath)) {
  throw ("Shared isolation quarantine helpers not found: {0}" -f $sharedIsolationQuarantinePath)
}
. $sharedIsolationQuarantinePath

$sharedIsolationStrategyPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Strategy.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationStrategyPath)) {
  throw ("Shared isolation strategy helpers not found: {0}" -f $sharedIsolationStrategyPath)
}
. $sharedIsolationStrategyPath

$sharedIsolationErrorDumpPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-ErrorDump.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationErrorDumpPath)) {
  throw ("Shared isolation error dump helpers not found: {0}" -f $sharedIsolationErrorDumpPath)
}
. $sharedIsolationErrorDumpPath

$sharedIsolationHashCachePath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-HashCache.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationHashCachePath)) {
  throw ("Shared hash cache helpers not found: {0}" -f $sharedIsolationHashCachePath)
}
. $sharedIsolationHashCachePath

$sharedLegacyPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Legacy.ps1"
if (-not (Test-Path -LiteralPath $sharedLegacyPath)) {
  throw ("Shared legacy helpers not found: {0}" -f $sharedLegacyPath)
}
. $sharedLegacyPath

$sharedStageResultPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-StageResult.ps1"
if (-not (Test-Path -LiteralPath $sharedStageResultPath)) {
  throw ("Shared stage result helpers not found: {0}" -f $sharedStageResultPath)
}
. $sharedStageResultPath

$sharedIsolationDecisionsPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Decisions.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationDecisionsPath)) {
  throw ("Shared isolation decision helpers not found: {0}" -f $sharedIsolationDecisionsPath)
}
. $sharedIsolationDecisionsPath

$isolateBaselinePath = Join-Path -Path $PSScriptRoot -ChildPath "Isolate-Incompatible-Mod.Baseline.ps1"
if (-not (Test-Path -LiteralPath $isolateBaselinePath)) {
  throw ("Isolation baseline script not found: {0}" -f $isolateBaselinePath)
}

$isolateStrategyPath = Join-Path -Path $PSScriptRoot -ChildPath "Isolate-Incompatible-Mod.Strategy.ps1"
if (-not (Test-Path -LiteralPath $isolateStrategyPath)) {
  throw ("Isolation strategy script not found: {0}" -f $isolateStrategyPath)
}

$isolateCulpritFinalizePath = Join-Path -Path $PSScriptRoot -ChildPath "Isolate-Incompatible-Mod.CulpritFinalize.ps1"
if (-not (Test-Path -LiteralPath $isolateCulpritFinalizePath)) {
  throw ("Isolation culprit finalize script not found: {0}" -f $isolateCulpritFinalizePath)
}

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

$effectiveIsolationStrategy = if ($UseLinearIsolation) { "Linear" } else { "Exponential" }
if (-not $UseLinearIsolation -and $UseDependencyAwareOrdering) {
  if ($DependencyAwareForceLinearIsolation) {
    $effectiveIsolationStrategy = "Linear"
    Write-Host "Dependency-aware ordering forces linear isolation strategy." -ForegroundColor Gray
  } else {
    $effectiveIsolationStrategy = "Hybrid"
    Write-Host "Dependency-aware ordering enables hybrid isolation strategy." -ForegroundColor Gray
  }
}
if ($BinaryLinearThreshold -lt 1) { $BinaryLinearThreshold = 1 }




























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

$candidateMods = @(Get-ChildItem -LiteralPath $GameModsDir -Filter "*.jar" -File -ErrorAction Stop |
    Sort-Object -Property LastWriteTime -Descending)

$script:dependencyAwareTierByJarName = @{}
$script:dependencyAwareStatsByJarName = @{}
$script:dependencyPriorityDecisionByJarName = @{}
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
    if (-not [string]::IsNullOrWhiteSpace($name)) {
      $excludeSet[$name.ToLowerInvariant()] = $true
    }
  }
  $candidateMods = @($candidateMods | Where-Object { -not $excludeSet.ContainsKey($_.Name.ToLowerInvariant()) })
}

if ($MaxModsToTest -gt 0 -and $candidateMods.Count -gt $MaxModsToTest) {
  $candidateMods = @($candidateMods | Select-Object -First $MaxModsToTest)
}

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

  if ($script:mcccCacheEnabled -and $passedCount -gt 0 -and $candidateMods -and $candidateMods.Count -gt 0) {
    foreach ($mod in $candidateMods) {
      $hash = Get-Sha256LowerHex -Path $mod.FullName -Retries $HashCacheHashRetryCount -DelayMs $HashCacheHashRetryDelayMs
      if ([string]::IsNullOrWhiteSpace($hash)) { continue }
      if (Test-McccHashPassed -Cache $script:mcccCache -Sha256LowerHex $hash) {
        $script:mcccKnownGoodJarNameSet[$mod.Name.ToLowerInvariant()] = $hash
      }
    }

    if ($script:mcccKnownGoodJarNameSet.Count -gt 0) {
      $candidateMods = @($candidateMods | Where-Object { -not $script:mcccKnownGoodJarNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
      Write-Host ("Hash cache: skipping {0} previously passed mod(s)." -f $script:mcccKnownGoodJarNameSet.Count) -ForegroundColor Gray
    }
  }
}

# * Apply dependency-aware ordering (tiers by number of incoming dependents).
if ($UseDependencyAwareOrdering -and $candidateMods -and $candidateMods.Count -gt 0) {
  try {
    if ($DependencyAwareTier2MaxDependents -lt 0) { $DependencyAwareTier2MaxDependents = 0 }
    if ($DependencyAwareTier3MaxDependents -lt $DependencyAwareTier2MaxDependents) {
      $DependencyAwareTier3MaxDependents = $DependencyAwareTier2MaxDependents
    }
    if ($DependencyAwareExponentialMaxTier -lt 0) { $DependencyAwareExponentialMaxTier = 0 }
    if ($DependencyAwareExponentialMaxTier -gt 4) { $DependencyAwareExponentialMaxTier = 4 }
    if ($DependencyAwareQuickIsolateMaxTier -lt 0) { $DependencyAwareQuickIsolateMaxTier = 0 }
    if ($DependencyAwareQuickIsolateMaxTier -gt 4) { $DependencyAwareQuickIsolateMaxTier = 4 }

    $countMode = $DependencyAwareOrderingCountMode
    if ([string]::IsNullOrWhiteSpace($countMode)) { $countMode = "RequiredOnly" }

    $dependencyMap = $null
    if ($DependencyMapSource -ne "Internal") {
      $dependencyMap = Get-DependencyMapFromSource -ScanPath $GameModsDir
    }

    if ($dependencyMap) {
      Initialize-DependencyMapCache -DependencyMap $dependencyMap
      $depMap = Get-DependentModCountsFromDependencyMap -DependencyMap $dependencyMap -CountMode $countMode

      $mapScanPath = ""
      if ($dependencyMap.PSObject.Properties.Name -contains "Scan") {
        $mapScanPath = [string]$dependencyMap.Scan.Path
      }
      if (-not [string]::IsNullOrWhiteSpace($mapScanPath) -and (-not [string]::Equals($mapScanPath, $GameModsDir, [System.StringComparison]::OrdinalIgnoreCase))) {
        Write-Host ("Warning: dependency map scan path differs from GameModsDir: {0}" -f $mapScanPath) -ForegroundColor Yellow
      } else {
        Write-Host ("Dependency map loaded from source: {0}" -f $DependencyMapSource) -ForegroundColor Gray
      }
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
        $script:dependencyAwareStatsByJarName[$jarKey] = [pscustomobject]@{
          DependentCount = [int]$depCount
          Known = [bool]$known
        }
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
        if (-not $script:dependencyAwareStatsByJarName.ContainsKey($jarKey)) {
          $script:dependencyAwareStatsByJarName[$jarKey] = [pscustomobject]@{
            DependentCount = [int]$depCount
            Known = [bool]$known
          }
        }
      }

      $candidateMods = @($candidateMods | Sort-Object -Property `
          @{ Expression = { $_.DependentModTier }; Ascending = $true }, `
          @{ Expression = { $_.LastWriteTime }; Descending = $true }, `
          @{ Expression = { $_.Name }; Ascending = $true })
    } else {
      Write-Host "Dependency-aware ordering enabled, but dependency map is empty. Using date ordering." -ForegroundColor Gray
    }
  } catch {
    Write-Host ("Warning: dependency-aware ordering failed: {0}. Using date ordering." -f $_.Exception.Message) -ForegroundColor Yellow
  }
}

if (-not $candidateMods -or $candidateMods.Count -eq 0) {
  Write-Host "No jar mods found to test." -ForegroundColor Yellow
  exit 0
}

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$gameLegacyRoot = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
$gameLegacyTempRoot = Join-Path -Path $gameLegacyRoot -ChildPath "temp"
$gameQuarantineDir = Join-Path -Path $gameLegacyTempRoot -ChildPath ("isolate-{0}" -f $runId)
$storageQuarantineDir = $null
if ($useStorage) {
  $storageLegacyRoot = Join-Path -Path $StorageModsDir -ChildPath $StorageLegacyFolderName
  $storageLegacyTempRoot = Join-Path -Path $storageLegacyRoot -ChildPath "temp"
  $storageQuarantineDir = Join-Path -Path $storageLegacyTempRoot -ChildPath ("isolate-{0}" -f $runId)
}

Write-Host ("Mods to test: {0}" -f $candidateMods.Count) -ForegroundColor Cyan
Write-Host ("Quarantine dir: {0}" -f $gameQuarantineDir) -ForegroundColor Gray
if ($useStorage) {
  Write-Host ("Storage quarantine dir: {0}" -f $storageQuarantineDir) -ForegroundColor Gray
}
Write-Host ("Isolation strategy: {0}" -f $effectiveIsolationStrategy) -ForegroundColor Gray
if ($effectiveIsolationStrategy -eq "Exponential") {
  Write-Host ("Binary refinement threshold: {0}" -f $BinaryLinearThreshold) -ForegroundColor Gray
}
if ($effectiveIsolationStrategy -eq "Hybrid") {
  $linearTierStart = if ($DependencyAwareExponentialMaxTier -lt 1) { 1 } else { [Math]::Min(4, $DependencyAwareExponentialMaxTier + 1) }
  Write-Host ("Гибридные уровни: экспоненциально<= {0}, линейно>= {1}" -f $DependencyAwareExponentialMaxTier, $linearTierStart) -ForegroundColor Gray
  if ($DependencyAwareExponentialMaxTier -gt 0) {
    Write-Host ("Binary refinement threshold: {0}" -f $BinaryLinearThreshold) -ForegroundColor Gray
  }
}

if ($DryRun) {
  foreach ($mod in $candidateMods) {
    if ($mod.PSObject.Properties.Name -contains "DependentModTier") {
      Write-Host ("План: {0} | уровень={1} | dependents={2} | known={3} | mtime={4}" -f $mod.Name, $mod.DependentModTier, $mod.DependentModCount, $mod.DependentModCountKnown, $mod.LastWriteTime) -ForegroundColor Gray
    } else {
      Write-Host ("Plan: {0} ({1})" -f $mod.Name, $mod.LastWriteTime) -ForegroundColor Gray
    }
  }
  Write-Host "Dry run complete. No changes made." -ForegroundColor Green
  exit 0
}

if ($PrintCursorOffset) {
  $launcherWindow = Start-LauncherIfNeeded -TitlePattern $LauncherWindowTitlePattern `
    -ExePath $LauncherExePath `
    -ExeArguments $LauncherArguments `
    -AppendAutoLaunch ([bool]$UseAutoLaunch) `
    -TimeoutSeconds $LauncherWindowTimeoutSeconds
  if ($null -eq $launcherWindow) {
    throw "Launcher window not found."
  }
  [void][MCCompatWin32]::SetForegroundWindow($launcherWindow.Handle)
  Start-Sleep -Milliseconds 150
  $offsets = Get-CursorOffsetRelativeToWindow -Handle $launcherWindow.Handle
  Write-Host ("Cursor offsets: X={0}, Y={1}" -f $offsets.OffsetX, $offsets.OffsetY) -ForegroundColor Gray

  if ($PlayClickOffsetX -lt 0 -or $PlayClickOffsetY -lt 0) {
    $PlayClickOffsetX = $offsets.OffsetX
    $PlayClickOffsetY = $offsets.OffsetY
    Write-Host ("Using cursor offsets for click: X={0}, Y={1}" -f $PlayClickOffsetX, $PlayClickOffsetY) -ForegroundColor Cyan
  }
}

$movedItems = New-Object System.Collections.Generic.List[object]
$movedJarNameSet = @{}
$pinnedJarNameSet = @{}
$script:lastBaselinePinnedKey = ""
$baselineSignature = ""
$baselineEvidenceKey = ""
$activeBaselineSignature = ""
# * Used by dot-sourced Shared-Isolation-Strategy.ps1 (hybrid isolation).
# * PSScriptAnalyzer cannot see cross-script usage; suppress with explicit reference.
$script:activeBaselineEvidenceKey = ""
$null = $script:activeBaselineEvidenceKey
$baselineOutcome = "Unknown"
$mcVersionForLegacy = "unknown"
$exitCode = 0
$culpritJarNames = @()
$culpritMoves = New-Object System.Collections.Generic.List[object]
$stopReason = ""
$hadError = $false
$wasCtrlC = $false
$script:lastOutcomeHandleId = 0
$baselineSucceeded = $false
$skipIsolation = $false
$phase = "init"
$isolationStartTime = Get-Date


try {
  . $isolateBaselinePath
  . $isolateStrategyPath
} catch [System.OperationCanceledException] {
  $hadError = $true
  $cancelMessage = [string]$_.Exception.Message
  if ($cancelMessage -match "^MCCompatUserCancelKeepChanges:") {
    $KeepMovedModsOnFailure = $true
    Write-Host "Launch canceled by user. Keeping current mod isolation state." -ForegroundColor Yellow
  } else {
    Write-Host "Launch canceled by user. Rolling back current mod changes." -ForegroundColor Yellow
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
    Write-Host ("Phase: {0}" -f $phase) -ForegroundColor Gray
  } else {
    Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Phase: {0}" -f $phase) -ForegroundColor Gray
  }
  $exitCode = 1
} finally {
  if ($wasCtrlC) {
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Isolation interrupted by user (Ctrl+C). Restoring mods..." -ForegroundColor Yellow
    Write-Host ("Phase at interruption: {0}" -f $phase) -ForegroundColor Gray
  }
  if (-not $DryRun) {
    # * Ensure the game is closed before restore/exit.
    [void](Stop-ConfiguredGameProcess -StartedAfter $isolationStartTime)
    [void](Wait-ConfiguredGameExit -StartedAfter $isolationStartTime -WarningContext "Isolation cleanup")
  }
  if (-not $DryRun -and $movedItems.Count -gt 0) {
    if ($hadError -and $KeepMovedModsOnFailure) {
      Write-Host "Keeping moved mods due to failure." -ForegroundColor Yellow
    } else {
      # * On unexpected errors, restore everything. Culprit selection is unreliable in this state.
      $excludeSet = @{}
      if (-not $hadError) {
        foreach ($name in $culpritJarNames) {
          if (-not [string]::IsNullOrWhiteSpace($name)) { $excludeSet[$name] = $true }
        }
      }
      $restoreCount = 0
      foreach ($item in $movedItems) {
        if ($excludeSet.Count -gt 0 -and $excludeSet.ContainsKey($item.JarName)) {
          continue
        }
        if (-not [string]::IsNullOrWhiteSpace($item.GameQuarantine)) {
          $restoreGame = Restore-FromQuarantine -SourcePath $item.GameQuarantine `
            -DestDir $GameModsDir `
            -IsDryRun $false `
            -AllowOverwrite ([bool]$ForceRestore)
          if ($restoreGame) {
            $restoreCount++
            Write-Verbose ("Restored game mod: {0}" -f $restoreGame)
          }
        }
        if ($useStorage -and -not [string]::IsNullOrWhiteSpace($item.StorageQuarantine)) {
          $restoreStorage = Restore-FromQuarantine -SourcePath $item.StorageQuarantine `
            -DestDir $StorageModsDir `
            -IsDryRun $false `
            -AllowOverwrite ([bool]$ForceRestore)
          if ($restoreStorage) {
            Write-Verbose ("Restored storage mod: {0}" -f $restoreStorage)
          }
        }
      }
      if ($restoreCount -gt 0) {
        Write-Host ("Restored {0} mod(s) from quarantine." -f $restoreCount) -ForegroundColor Green
      }
    }
  }

  . $isolateCulpritFinalizePath
}

if ($script:blockedByDependency) {
  $missLabel = if ($script:blockedDependencyMissing.Count -gt 0) { $script:blockedDependencyMissing -join ", " } else { "<none>" }
  $reqLabel = if ($script:blockedDependencyRequiring.Count -gt 0) { $script:blockedDependencyRequiring -join ", " } else { "<none>" }
  $ctxLabel = if ([string]::IsNullOrWhiteSpace($script:blockedDependencyContext)) { "baseline" } else { $script:blockedDependencyContext }
  Write-Host ("Isolation stopped due to dependency dialog in {0}. Missing deps: {1}; Requiring mods: {2}" -f $ctxLabel, $missLabel, $reqLabel) -ForegroundColor Yellow
  if ([string]::IsNullOrWhiteSpace($stopReason)) {
    $stopReason = "dependency_dialog"
  }
  $exitCode = 2
} elseif ($baselineSucceeded) {
  Write-Host "Baseline launch succeeded. No isolation needed." -ForegroundColor Green
  $exitCode = 0
}

if (-not $script:blockedByDependency) {
  if ($culpritJarNames -and $culpritJarNames.Count -gt 0) {
    Write-Host ("Culprit candidate(s): {0}" -f (($culpritJarNames | Sort-Object -Unique) -join ", ")) -ForegroundColor Green
    Write-Host ("Stop reason: {0}" -f $stopReason) -ForegroundColor Cyan
    $exitCode = 0
  } elseif ((-not $hadError) -and (-not $baselineSucceeded)) {
    Write-Host "No error change or successful launch detected." -ForegroundColor Yellow
    $exitCode = 2
  }
}

if ($EmitResultObject) {
  $culpritSet = @{}
  foreach ($n in $culpritJarNames) {
    if (-not [string]::IsNullOrWhiteSpace($n)) {
      $culpritSet[$n.ToLowerInvariant()] = $true
    }
  }

  $fastForward = New-Object System.Collections.Generic.List[string]
  $seen = @{}
  foreach ($item in $movedItems) {
    if ($null -eq $item) { continue }
    $name = [string]$item.JarName
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $key = $name.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    if ($culpritSet.ContainsKey($key)) { continue }
    $fastForward.Add($name)
  }

  $stageResultParams = @{
    Stage = "Isolation"
    Type = "IsolationResult"
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
    BaselineOutcome = $baselineOutcome
    BaselineSignature = $baselineSignature
    BaselineEvidenceKey = $baselineEvidenceKey
    StopReason = $stopReason
    ExtraFields = @{
      FastForwardJarNames = @($fastForward.ToArray())
      PreIsolateJarNames  = @($PreIsolateJarNames)
    }
  }
  Write-Output (New-StageResult @stageResultParams)
}

exit $exitCode
