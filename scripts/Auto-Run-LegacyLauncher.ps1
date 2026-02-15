<#
.SYNOPSIS
Automates Legacy Launcher runs and triggers mod cleanup on crash dialog.

.DESCRIPTION
Starts or attaches to Legacy Launcher, clicks Play, waits for crash/fabric dialogs, and runs
Check-Mod-Compatibility.ps1 when a crash dialog is detected. Use -CheckScriptArguments to pass
flags to the compatibility checker (for example, -NoLegacy or -GameLegacy). When -Verbose is used
on this script, -Verbose is forwarded to the checker to enable compatibility logs.

.PARAMETER LauncherExePath
Optional path to Legacy Launcher executable. If empty, attaches to a running launcher window.

.PARAMETER LauncherArguments
Additional launcher CLI arguments.

.PARAMETER UseAutoLaunch
If true (default), appends --launch to enable auto-start.
Disable with -DisableAutoLaunch or -UseAutoLaunch:$false.

.PARAMETER DisableAutoLaunch
If set, disables the default auto-start (--launch) behavior.

.PARAMETER LauncherWindowTitlePattern
Partial title of the launcher main window.

.PARAMETER PlayButtonNames
Button names to start the game.

.PARAMETER PlayClickOffsetX
Optional click offset (pixels) relative to the top-left of the launcher window.

.PARAMETER PlayClickOffsetY
Optional click offset (pixels) relative to the top-left of the launcher window.

.PARAMETER UseEnterFallback
If true, sends ENTER when play element is not found.

.PARAMETER EnableBroadUiSearch
If true, enables a broad UI Automation fallback search which can be slow on some launcher builds.
Disabled by default to avoid hangs; prefer -PlayClickOffsetX/-PlayClickOffsetY or Enter fallback.

.PARAMETER PrintCursorOffset
If set, captures current mouse offsets relative to the launcher window and prints them.
If PlayClickOffsetX/Y are not set, uses the captured offsets for click.

.PARAMETER DeleteFromGameMods
If true (default), passes -DeleteFromGameMods to compatibility checker.
Set to false to keep game-side legacy behavior (for example, -DeleteFromGameMods:$false).

.PARAMETER NoLegacy
If set, passes -NoLegacy to compatibility checker.

.PARAMETER GameLegacy
If set, passes -GameLegacy to compatibility checker.

.PARAMETER CheckScriptArguments
Additional arguments to pass to Check-Mod-Compatibility.ps1.

.PARAMETER IgnoreModIds
If set, ignores these mod IDs during compatibility cleanup.

.PARAMETER CrashCloseClickOffsetX
Optional click offset for closing crash dialog (relative to crash window).

.PARAMETER CrashCloseClickOffsetY
Optional click offset for closing crash dialog (relative to crash window).

.PARAMETER CrashWindowTitlePatterns
Crash dialog title fragments.

.PARAMETER FabricWindowTitlePatterns
Fabric or dependency dialog title fragments.

.PARAMETER AutoHandleFabricDialog
If true, attempts to auto-handle Fabric dialogs by running compatibility cleanup when no
missing dependencies are detected in logs.

.PARAMETER CheckScriptPath
Path to compatibility script.

.PARAMETER IsolateOnNoChanges
If true (default), runs Isolate-Incompatible-Mod.ps1 when compatibility cleanup makes no changes
(i.e., when Check-Mod-Compatibility.ps1 exits with code 3). Disable with -DisableIsolationOnNoChanges
or -IsolateOnNoChanges:$false.

.PARAMETER DisableIsolationOnNoChanges
If set, disables the default isolation run when compatibility cleanup makes no changes.

.PARAMETER IsolateScriptPath
Path to isolation script.

.PARAMETER IsolateScriptArguments
Additional arguments to pass to Isolate-Incompatible-Mod.ps1.

.PARAMETER UseLinearIsolation
If set, passes -UseLinearIsolation to Isolate-Incompatible-Mod.ps1 (disables exponential probing).

.PARAMETER BinaryLinearThreshold
If set (>0), passes -BinaryLinearThreshold to Isolate-Incompatible-Mod.ps1 for binary refinement.

.PARAMETER NoCache
If set, passes -NoCache to Layer-Mods.ps1 / Isolate-Incompatible-Mod.ps1 to force repeated launch checks.

.PARAMETER LogPath
Optional log path to pass into Check-Mod-Compatibility.ps1.

.PARAMETER ProfileName
Optional config profile name (section Profile:<name> in config.ini) for advanced settings.

.PARAMETER LauncherWindowTimeoutSeconds
Wait time to find launcher window after start.

.PARAMETER OutcomeTimeoutSeconds
Time window to detect outcomes after clicking Play.

.PARAMETER PollIntervalSeconds
Polling interval.

.PARAMETER SuccessGraceSeconds
Seconds to detect a game process start after clicking Play. If no start is observed
within this window, outcome is treated as NoLaunch.

.PARAMETER GameProcessNames
Process names to detect a successful launch (used with SuccessGraceSeconds).

.PARAMETER CrashCloseDelaySeconds
Delay before closing crash dialog automatically.

.PARAMETER DryRun
If set, does not click or run cleanup; prints what would happen.

.PARAMETER Help
Show detailed help for this script and exit.

.EXAMPLE
.\Auto-Run-LegacyLauncher.ps1

.EXAMPLE
.\Auto-Run-LegacyLauncher.ps1 -LauncherExePath "C:\Path\LegacyLauncher.exe" -UseAutoLaunch

.EXAMPLE
.\Auto-Run-LegacyLauncher.ps1 -DisableIsolationOnNoChanges -DeleteFromGameMods:$false -DisableAutoLaunch

.EXAMPLE
.\Auto-Run-LegacyLauncher.ps1 -NoLegacy -CheckScriptArguments @("-Verbose")
#>

[CmdletBinding()]
param(
  # * Optional path to Legacy Launcher executable. If empty, attaches to a running launcher window.
  [Parameter(Mandatory = $false)]
  [string]$LauncherExePath = "",

  # * Additional launcher CLI arguments.
  [Parameter(Mandatory = $false)]
  [string[]]$LauncherArguments = @(),

  # * If set, appends --launch to enable auto-start.
  [Parameter(Mandatory = $false)]
  [Alias("Auto")]
  [bool]$UseAutoLaunch = $true,

  # * If set, disables the default auto-start (--launch) behavior.
  [Parameter(Mandatory = $false)]
  [switch]$DisableAutoLaunch,

  # * Partial title of the launcher main window.
  [Parameter(Mandatory = $false)]
  [string]$LauncherWindowTitlePattern = "Legacy Launcher",

  # * Button names to start the game.
  [Parameter(Mandatory = $false)]
  [string[]]$PlayButtonNames = @("Launch", "Play", "Start"),

  # * Optional click offsets (pixels) relative to the top-left of the launcher window.
  # * Set both to enable coordinate-based click fallback.
  [Parameter(Mandatory = $false)]
  [int]$PlayClickOffsetX = -1,

  [Parameter(Mandatory = $false)]
  [int]$PlayClickOffsetY = -1,

  # * If true, sends ENTER when play element is not found.
  [Parameter(Mandatory = $false)]
  [bool]$UseEnterFallback = $true,

  # * Enables a broad UI Automation fallback search (can be slow).
  [Parameter(Mandatory = $false)]
  [bool]$EnableBroadUiSearch = $false,

  # * If set, prints current mouse offsets relative to the launcher window and uses them for click.
  [Parameter(Mandatory = $false)]
  [switch]$PrintCursorOffset,

  # * If set, passes -DeleteFromGameMods to compatibility checker.
  [Parameter(Mandatory = $false)]
  [bool]$DeleteFromGameMods = $true,

  # * If set, passes -NoLegacy to compatibility checker.
  [Parameter(Mandatory = $false)]
  [switch]$NoLegacy,

  # * If set, passes -GameLegacy to compatibility checker.
  [Parameter(Mandatory = $false)]
  [switch]$GameLegacy,

  # * Optional click offsets for closing crash dialog (relative to crash window).
  [Parameter(Mandatory = $false)]
  [int]$CrashCloseClickOffsetX = -1,

  [Parameter(Mandatory = $false)]
  [int]$CrashCloseClickOffsetY = -1,

  # * Crash dialog title fragments.
  [Parameter(Mandatory = $false)]
  [string[]]$CrashWindowTitlePatterns = @("Something broke"),

  # * Fabric or dependency dialog title fragments.
  [Parameter(Mandatory = $false)]
  [string[]]$FabricWindowTitlePatterns = @("Fabric Loader", "owo-sentinel"),

  # * If true, auto-handles Fabric dialogs by running compatibility cleanup when no missing deps are detected.
  [Parameter(Mandatory = $false)]
  [bool]$AutoHandleFabricDialog = $true,

  # * Path to compatibility script.
  [Parameter(Mandatory = $false)]
  [string]$CheckScriptPath = "",

  # * If set, runs Isolate-Incompatible-Mod.ps1 when cleanup makes no changes.
  [Parameter(Mandatory = $false)]
  [bool]$IsolateOnNoChanges = $true,

  # * If set, disables the default isolation run on "no changes".
  [Parameter(Mandatory = $false)]
  [switch]$DisableIsolationOnNoChanges,

  # * Path to isolation script.
  [Parameter(Mandatory = $false)]
  [string]$IsolateScriptPath = "",

  # * Additional arguments to pass to Isolate-Incompatible-Mod.ps1.
  [Parameter(Mandatory = $false)]
  [string[]]$IsolateScriptArguments = @(),

  # * If set, forces linear isolation in Isolate-Incompatible-Mod.ps1.
  [Parameter(Mandatory = $false)]
  [switch]$UseLinearIsolation,

  # * If set (>0), overrides binary-to-linear threshold for refinement in Isolate-Incompatible-Mod.ps1.
  [Parameter(Mandatory = $false)]
  [int]$BinaryLinearThreshold = 0,

  # * Enables extended stability confirmation (60s) in Layer-Mods.ps1 instead of the default 20s.
  [Parameter(Mandatory = $false)]
  [switch]$ThoroughStabilityCheck,

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

  # * If true, persists launch-config dedup cache across runs.
  [Parameter(Mandatory = $false)]
  [bool]$UsePersistentLaunchConfigCache = $true,

  # * Persistent launch-config cache file name stored in GameModsDir.
  [Parameter(Mandatory = $false)]
  [string]$SessionLaunchConfigCacheFileName = "MCCC.launch-config-cache.json",

  # * Max number of launch-config entries to keep in the persistent cache.
  [Parameter(Mandatory = $false)]
  [int]$SessionLaunchConfigCacheMaxEntries = 5000,

  # * If set, disables launch-config dedup cache in Layer-Mods.ps1 / Isolate-Incompatible-Mod.ps1.
  [Parameter(Mandatory = $false)]
  [switch]$NoCache,

  # * If true, auto-restores mods from legacy log after user interruption (Ctrl+C).
  [Parameter(Mandatory = $false)]
  [bool]$AutoRestoreOnInterrupt = $true,

  # * Additional arguments to pass to Check-Mod-Compatibility.ps1.
  [Parameter(Mandatory = $false)]
  [string[]]$CheckScriptArguments = @(),

  # * If set, ignores these mod IDs during compatibility cleanup.
  [Parameter(Mandatory = $false)]
  [string[]]$IgnoreModIds = @(),

  # * Optional log path to pass into Check-Mod-Compatibility.ps1.
  [Parameter(Mandatory = $false)]
  [string]$LogPath = "",

  # * Optional config profile name (section Profile:<name> in config.ini).
  [Parameter(Mandatory = $false)]
  [Alias("Profile")]
  [string]$ProfileName = "",

  # * Wait time to find launcher window after start.
  [Parameter(Mandatory = $false)]
  [int]$LauncherWindowTimeoutSeconds = 60,

  # * Time window to detect outcomes after clicking Play.
  [Parameter(Mandatory = $false)]
  [int]$OutcomeTimeoutSeconds = 60,

  # * Polling interval.
  [Parameter(Mandatory = $false)]
  [int]$PollIntervalSeconds = 2,

  # * Seconds to detect game process start after clicking Play.
  [Parameter(Mandatory = $false)]
  [int]$SuccessGraceSeconds = 15,

  # * Process names to detect a successful launch.
  [Parameter(Mandatory = $false)]
  [string[]]$GameProcessNames = @("javaw", "java", "Minecraft"),

  # * How many times to attempt triggering Play per launch attempt when no game start is detected.
  [Parameter(Mandatory = $false)]
  [int]$PlayClickMaxAttempts = 2,

  # * Delay before closing crash dialog automatically.
  [Parameter(Mandatory = $false)]
  [int]$CrashCloseDelaySeconds = 5,

  # * If set, does not click or run cleanup; prints what would happen.
  [Parameter(Mandatory = $false)]
  [switch]$DryRun,

  # * Show detailed help and exit.
  [Parameter(Mandatory = $false)]
  [switch]$Help
)

$sharedLocalizationPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Localization.ps1"
if (-not (Test-Path -LiteralPath $sharedLocalizationPath)) {
  throw ("Shared localization helpers not found: {0}" -f $sharedLocalizationPath)
}
. $sharedLocalizationPath
Initialize-McccLocalization -StartDir $PSScriptRoot | Out-Null
Enable-McccConsoleLocalization

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath ".."))
$transcriptLogPath = Join-Path -Path $projectRoot -ChildPath "MCCC.log"
$legacyLogPath = Join-Path -Path $projectRoot -ChildPath "legacy.log"
$script:compatReportDir = Join-Path -Path $projectRoot -ChildPath "logs"
if (-not (Test-Path -LiteralPath $script:compatReportDir)) {
  New-Item -ItemType Directory -Path $script:compatReportDir -Force | Out-Null
}
$enableTranscript = $true
$transcriptStarted = $false
$script:OutcomeTimeoutSecondsBound = $PSBoundParameters.ContainsKey("OutcomeTimeoutSeconds")

# * Keeps session report data initialized for early exits.
$sessionIsolationCulpritByJar = @{}
$sessionIsolationCulpritHistoryByJar = @{}
$sessionRecoveredJarNames = @{}
$sessionMixinConflicts = @()

# * Hash-cache session controls (auto-disable after an unresolved crash).
$script:hashCacheAttemptedThisSession = $false
$script:hashCacheDisabledThisSession = $false
$script:suppressTranscriptCulpritInference = $false

# * Session timing (initialized early so it's available in finally block).
$sessionStartTime = Get-Date

# * Tracks whether the session was interrupted by the user (Ctrl+C).
$sessionInterrupted = $false
$autoRestoreExitCode = 0

try {
  if ($enableTranscript) {
    if (Test-Path -LiteralPath $transcriptLogPath) {
      Remove-Item -LiteralPath $transcriptLogPath -Force -ErrorAction Stop
    }
    Start-Transcript -Path $transcriptLogPath -Force | Out-Null
    $transcriptStarted = $true
  }

  # * Write session header to legacy.log (append-only, session-divided).
  Add-Content -LiteralPath $legacyLogPath -Value ("" + [Environment]::NewLine + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))

  $effectiveAutoLaunch = ([bool]$UseAutoLaunch) -and (-not [bool]$DisableAutoLaunch)

if ($Help) {
  Get-Help -Full -Name $PSCommandPath
  return
}

# * Load shared config helpers.
$sharedConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Config.ps1"
if (-not (Test-Path -LiteralPath $sharedConfigPath)) {
  throw ("Shared config helpers not found: {0}" -f $sharedConfigPath)
}
. $sharedConfigPath

# * Optional: MCCC.json hash cache helpers (used to speed up layering/isolation).
$sharedIsolationHashCachePath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-HashCache.ps1"
if (Test-Path -LiteralPath $sharedIsolationHashCachePath) {
  . $sharedIsolationHashCachePath
} elseif ($UseHashCache) {
  throw ("Shared hash cache helpers not found: {0}" -f $sharedIsolationHashCachePath)
}

$runtimeConfig = Initialize-McccRuntimeConfig `
  -StartDir $PSScriptRoot `
  -BoundParameters $PSBoundParameters `
  -LogPath $LogPath `
  -LauncherExePath $LauncherExePath `
  -AlwaysDefaultGameModsDir $false `
  -DefaultStorageToGame $false
$configIni = $runtimeConfig.Ini
$LauncherExePath = $runtimeConfig.Paths.LauncherExePath
$LogPath = $runtimeConfig.Paths.LogPath

$profileTypeMap = @{
  LauncherWindowTitlePattern = "string"
  PlayButtonNames = "string[]"
  PlayClickOffsetX = "int"
  PlayClickOffsetY = "int"
  PlayClickDelayMs = "int"
  PlayClickMaxAttempts = "int"
  UseEnterFallback = "bool"
  EnableBroadUiSearch = "bool"
  CrashWindowTitlePatterns = "string[]"
  FabricWindowTitlePatterns = "string[]"
  CrashCloseClickOffsetX = "int"
  CrashCloseClickOffsetY = "int"
  CrashCloseDelaySeconds = "int"
  AutoHandleFabricDialog = "bool"
  IgnoreModIds = "string[]"
  LauncherWindowTimeoutSeconds = "int"
  OutcomeTimeoutSeconds = "int"
  PollIntervalSeconds = "int"
  UseHashCache = "bool"
  HashCacheFileName = "string"
  HashCacheHashRetryCount = "int"
  HashCacheHashRetryDelayMs = "int"
  UsePersistentLaunchConfigCache = "bool"
  SessionLaunchConfigCacheFileName = "string"
  SessionLaunchConfigCacheMaxEntries = "int"
  SuccessGraceSeconds = "int"
  GameProcessNames = "string[]"
}
$profileOverrides = Get-ProfileOverride `
  -Ini $configIni `
  -BoundParameters $PSBoundParameters `
  -ProfileName $ProfileName `
  -KeyTypeMap $profileTypeMap
foreach ($key in $profileOverrides.Keys) {
  Set-Variable -Name $key -Value $profileOverrides[$key] -Scope Local
}

if (-not $PSBoundParameters.ContainsKey("CrashWindowTitlePatterns") -and (-not $profileOverrides.ContainsKey("CrashWindowTitlePatterns"))) {
  $CrashWindowTitlePatterns = Get-McccLocaleCrashWindowTitlePatternSet -StartDir $PSScriptRoot -FallbackPatterns $CrashWindowTitlePatterns
}

$stageMixinAnalysisEnabled = Get-IniBool -Ini $configIni -Section "Stages" -Key "EnableMixinAnalysis" -Default $true
$stageLayeringEnabled = Get-IniBool -Ini $configIni -Section "Stages" -Key "EnableLayering" -Default $true
$stageRecoveryEnabled = Get-IniBool -Ini $configIni -Section "Stages" -Key "EnableRecovery" -Default $true

$script:hashCacheGameModsDir = ""
$script:hashCachePath = ""
$script:hashCacheObject = $null
if (-not $DryRun -and $UseHashCache) {
  $script:hashCacheGameModsDir = $runtimeConfig.Paths.GameModsDir
  if (Test-Path -LiteralPath $script:hashCacheGameModsDir) {
    $script:hashCachePath = Get-McccHashCachePath -GameModsDir $script:hashCacheGameModsDir -FileName $HashCacheFileName
    $script:hashCacheObject = Read-McccHashCache -Path $script:hashCachePath
    try {
      if (-not (Test-Path -LiteralPath $script:hashCachePath)) {
        Write-McccHashCache -Path $script:hashCachePath -Cache $script:hashCacheObject
      }
    } catch {
      Write-Host ("Warning: failed to create hash cache file: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
      $script:hashCacheObject = $null
    }
  } else {
    Write-Host ("Warning: GameModsDir not found; hash cache disabled: {0}" -f $script:hashCacheGameModsDir) -ForegroundColor Yellow
    $script:hashCacheObject = $null
  }
}

# * Load shared UI helpers.
$sharedUiPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LauncherUi.ps1"
if (-not (Test-Path -LiteralPath $sharedUiPath)) {
  throw ("Shared UI helpers not found: {0}" -f $sharedUiPath)
}
. $sharedUiPath

# * Load shared log helpers required by Shared-Isolation-Launcher.ps1.
$sharedLogPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LogTools.ps1"
if (-not (Test-Path -LiteralPath $sharedLogPath)) {
  throw ("Shared log helpers not found: {0}" -f $sharedLogPath)
}
. $sharedLogPath

# * Load shared isolation log parsing helpers (used for Fabric dialog auto-handling).
$sharedIsolationLogPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-LogParsing.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationLogPath)) {
  throw ("Shared isolation log helpers not found: {0}" -f $sharedIsolationLogPath)
}
. $sharedIsolationLogPath

# * Load shared launcher/outcome helpers.
$sharedIsolationLauncherPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Launcher.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationLauncherPath)) {
  throw ("Shared isolation launcher helpers not found: {0}" -f $sharedIsolationLauncherPath)
}
. $sharedIsolationLauncherPath

# * Load shared stage result helpers.
$sharedStageResultPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-StageResult.ps1"
if (-not (Test-Path -LiteralPath $sharedStageResultPath)) {
  throw ("Shared stage result helpers not found: {0}" -f $sharedStageResultPath)
}
. $sharedStageResultPath

# * Load Auto-Run submodules.
$autoRunReportingPath = Join-Path -Path $PSScriptRoot -ChildPath "Auto-Run-LegacyLauncher.Reporting.ps1"
if (-not (Test-Path -LiteralPath $autoRunReportingPath)) {
  throw ("Auto-Run reporting helpers not found: {0}" -f $autoRunReportingPath)
}
. $autoRunReportingPath

$autoRunStageDispatchPath = Join-Path -Path $PSScriptRoot -ChildPath "Auto-Run-LegacyLauncher.StageDispatch.ps1"
if (-not (Test-Path -LiteralPath $autoRunStageDispatchPath)) {
  throw ("Auto-Run stage dispatch helpers not found: {0}" -f $autoRunStageDispatchPath)
}
. $autoRunStageDispatchPath

$autoRunRestorePath = Join-Path -Path $PSScriptRoot -ChildPath "Auto-Run-LegacyLauncher.Restore.ps1"
if (-not (Test-Path -LiteralPath $autoRunRestorePath)) {
  throw ("Auto-Run restore helpers not found: {0}" -f $autoRunRestorePath)
}
. $autoRunRestorePath

$autoRunSessionPath = Join-Path -Path $PSScriptRoot -ChildPath "Auto-Run-LegacyLauncher.Session.ps1"
if (-not (Test-Path -LiteralPath $autoRunSessionPath)) {
  throw ("Auto-Run session loop not found: {0}" -f $autoRunSessionPath)
}

if ([string]::IsNullOrWhiteSpace($CheckScriptPath)) {
  $CheckScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Check-Mod-Compatibility.ps1"
}

if (-not (Test-Path -LiteralPath $CheckScriptPath)) {
  throw ("Check script not found: {0}" -f $CheckScriptPath)
}

$effectiveIsolateOnNoChanges = ([bool]$IsolateOnNoChanges) -and (-not [bool]$DisableIsolationOnNoChanges)
if ($effectiveIsolateOnNoChanges -and (-not $stageLayeringEnabled)) {
  Write-Host "Layering/Isolation stage is disabled in config ([Stages].EnableLayering=false)." -ForegroundColor Gray
}
if ($effectiveIsolateOnNoChanges -and $stageLayeringEnabled) {
  if ([string]::IsNullOrWhiteSpace($IsolateScriptPath)) {
    $IsolateScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Isolate-Incompatible-Mod.ps1"
  }
  if (-not (Test-Path -LiteralPath $IsolateScriptPath)) {
    throw ("Isolation script not found: {0}" -f $IsolateScriptPath)
  }
}

# * Layering script: fallback strategy that adds mods in exponential batches.
$LayerScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Layer-Mods.ps1"
$layeringAvailable = $stageLayeringEnabled -and (Test-Path -LiteralPath $LayerScriptPath)

# * Mixin analysis script: targeted Mixin error resolution (runs before layering).
$MixinAnalysisScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Analyze-MixinErrors.ps1"
$mixinAnalysisAvailable = $stageMixinAnalysisEnabled -and (Test-Path -LiteralPath $MixinAnalysisScriptPath)

# * Recovery script: post-isolation phantom culprit recovery.
$RecoveryScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Recover-PhantomCulprits.ps1"
$recoveryAvailable = $stageRecoveryEnabled -and (Test-Path -LiteralPath $RecoveryScriptPath)

# * Session-level dependency map cache (built once after first failed launch).
$script:sessionDependencyMapPrepared = $false
$script:sessionDependencyMapPreparedReason = ""
$script:sessionDependencyMapAvailable = $false
$script:sessionDependencyMapJsonPath = ""
$script:sessionDependencyMapToolPath = Join-Path -Path $PSScriptRoot -ChildPath "..\tools\Analyze-JarDependencyMap.ps1"
$script:sessionDependencyMapOutDir = Join-Path -Path $PSScriptRoot -ChildPath "..\reports"

if (-not $stageMixinAnalysisEnabled) {
  Write-Host "Mixin analysis stage disabled in config ([Stages].EnableMixinAnalysis=false)." -ForegroundColor Gray
}
if (-not $stageLayeringEnabled) {
  Write-Host "Layering stage disabled in config ([Stages].EnableLayering=false)." -ForegroundColor Gray
}
if (-not $stageRecoveryEnabled) {
  Write-Host "Recovery stage disabled in config ([Stages].EnableRecovery=false)." -ForegroundColor Gray
}

# * Detect optional parameters on the compatibility checker.
$script:checkScriptSupportsSince = $false
try {
  $checkCmd = Get-Command -Name $CheckScriptPath -ErrorAction Stop
  if ($null -ne $checkCmd.Parameters -and $checkCmd.Parameters.ContainsKey("LogSinceTimestamp")) {
    $script:checkScriptSupportsSince = $true
  }
} catch {
  $script:checkScriptSupportsSince = $false
}

. $autoRunSessionPath
} catch [System.OperationCanceledException] {
  $sessionInterrupted = $true
  throw
} catch [System.Management.Automation.PipelineStoppedException] {
  $sessionInterrupted = $true
  throw
} finally {
  # * Auto-restore from legacy log when the session was interrupted (Ctrl+C).
  if ($sessionInterrupted -and $AutoRestoreOnInterrupt -and (-not $DryRun)) {
    $restoreScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "..\tools\Restore-ModsFromLog.ps1"
    if (Test-Path -LiteralPath $restoreScriptPath) {
      Write-Host "User interruption detected. Restoring mods from legacy log..." -ForegroundColor Yellow
      try {
        & $restoreScriptPath -SinceTimestamp $sessionStartTime -NoExit
        $restoreExitCode = [int]$LASTEXITCODE
        if ($restoreExitCode -ne 0) {
          Write-Host ("Warning: auto-restore failed: {0}" -f $restoreExitCode) -ForegroundColor Yellow
          $autoRestoreExitCode = $restoreExitCode
        }
      } catch {
        Write-Host ("Warning: auto-restore failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        $autoRestoreExitCode = 1
      }
    }
    else {
      Write-Host ("Warning: restore script not found: {0}" -f $restoreScriptPath) -ForegroundColor Yellow
      $autoRestoreExitCode = 1
    }
  }

  try {
    if (-not $DryRun) {
      [void](Stop-GameProcess -Names $GameProcessNames -StartedAfter $sessionStartTime)
    }
    if ($sessionIsolationCulpritHistoryByJar.Count -eq 0 -and (-not [bool]$script:suppressTranscriptCulpritInference) -and (Test-Path -LiteralPath $transcriptLogPath)) {
      try {
        $lines = Get-Content -LiteralPath $transcriptLogPath -ErrorAction Stop
        foreach ($line in $lines) {
          $m = [regex]::Match([string]$line, "^\s*Culprit identified:\s+(?<jar>.+?\.jar)\s*$", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
          if (-not $m.Success) { continue }
          $jarName = [string]$m.Groups["jar"].Value
          if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
          $key = $jarName.ToLowerInvariant()
          if ($sessionIsolationCulpritHistoryByJar.ContainsKey($key)) { continue }
          $move = [pscustomobject]@{
            JarName = $jarName
            GameModsDir = $script:hashCacheGameModsDir
            StorageModsDir = ""
            StorageLegacyPath = ""
            GameLegacyPath = ""
            Minecraft = ""
            KeepCulpritInGameLegacy = $true
            CrashEvidenceKey = ""
            Stage = "unknown"
          }
          $sessionIsolationCulpritHistoryByJar[$key] = $move
        }
      } catch {
        Write-Verbose ("Failed to infer culprits from transcript: {0}" -f $_.Exception.Message)
      }
    }

    $latestCompatReportPath = Get-LatestCompatReportPath `
      -ReportDir $script:compatReportDir `
      -SinceTimestamp $sessionStartTime `
      -SinceSkewSeconds 5
    $reportParams = @{
      CulpritHistoryByJar = $sessionIsolationCulpritHistoryByJar
      CulpritCurrentByJar = $sessionIsolationCulpritByJar
      CompatReportPath = $latestCompatReportPath
      SessionStartTime = $sessionStartTime
      RecoveredJarNames = $sessionRecoveredJarNames
      MixinConflicts = $sessionMixinConflicts
    }
    Write-SessionReport @reportParams
  } catch {
    Write-Host ("Warning: failed to generate session report: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
  }
  if ($transcriptStarted) {
    Stop-Transcript | Out-Null
  }
  if ($autoRestoreExitCode -ne 0) {
    $global:LASTEXITCODE = $autoRestoreExitCode
  }
}
