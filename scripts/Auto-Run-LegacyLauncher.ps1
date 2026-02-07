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

.PARAMETER CrashCloseClickOffsetX
Optional click offset for closing crash dialog (relative to crash window).

.PARAMETER CrashCloseClickOffsetY
Optional click offset for closing crash dialog (relative to crash window).

.PARAMETER CrashWindowTitlePatterns
Crash dialog title fragments.

.PARAMETER FabricWindowTitlePatterns
Fabric or dependency dialog title fragments.

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

.PARAMETER LogPath
Optional log path to pass into Check-Mod-Compatibility.ps1.

.PARAMETER MaxAttempts
Deprecated: attempts are unlimited. Kept for compatibility.

.PARAMETER LauncherWindowTimeoutSeconds
Wait time to find launcher window after start.

.PARAMETER OutcomeTimeoutSeconds
Time window to detect outcomes after clicking Play.

.PARAMETER PollIntervalSeconds
Polling interval.

.PARAMETER SuccessGraceSeconds
Seconds a Minecraft process must live to consider launch successful.

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
  [string[]]$PlayButtonNames = @("Запустить", "Play", "Start"),

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
  [string[]]$CrashWindowTitlePatterns = @("Что-то сломалось"),

  # * Fabric or dependency dialog title fragments.
  [Parameter(Mandatory = $false)]
  [string[]]$FabricWindowTitlePatterns = @("Fabric Loader", "owo-sentinel"),

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

  # * If true, auto-restores mods from legacy log after user interruption (Ctrl+C).
  [Parameter(Mandatory = $false)]
  [bool]$AutoRestoreOnInterrupt = $true,

  # * Additional arguments to pass to Check-Mod-Compatibility.ps1.
  [Parameter(Mandatory = $false)]
  [string[]]$CheckScriptArguments = @(),

  # * Optional log path to pass into Check-Mod-Compatibility.ps1.
  [Parameter(Mandatory = $false)]
  [string]$LogPath = "",

  # * Deprecated: attempts are unlimited. Kept for compatibility.
  [Parameter(Mandatory = $false)]
  [int]$MaxAttempts = 1,

  # * Wait time to find launcher window after start.
  [Parameter(Mandatory = $false)]
  [int]$LauncherWindowTimeoutSeconds = 60,

  # * Time window to detect outcomes after clicking Play.
  [Parameter(Mandatory = $false)]
  [int]$OutcomeTimeoutSeconds = 60,

  # * Polling interval.
  [Parameter(Mandatory = $false)]
  [int]$PollIntervalSeconds = 2,

  # * Seconds a Minecraft process must live to consider launch successful.
  [Parameter(Mandatory = $false)]
  [int]$SuccessGraceSeconds = 15,

  # * Process names to detect a successful launch.
  [Parameter(Mandatory = $false)]
  [string[]]$GameProcessNames = @("javaw", "java", "Minecraft"),

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

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$transcriptLogPath = Join-Path -Path $PSScriptRoot -ChildPath "MCCC.log"
$enableTranscript = $PSBoundParameters.ContainsKey("Verbose")
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

# * Session timing (initialized early so it's available in finally block).
$sessionStartTime = Get-Date

# * Tracks whether the session was interrupted by the user (Ctrl+C).
$sessionInterrupted = $false

# * Session summary helpers.
function Get-LatestCompatReportPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ReportDir
  )

  if (-not (Test-Path -LiteralPath $ReportDir)) { return "" }
  $reports = Get-ChildItem -LiteralPath $ReportDir -Filter "compat-report-*.json" -File -ErrorAction SilentlyContinue |
    Sort-Object -Property LastWriteTime -Descending
  if (-not $reports -or $reports.Count -eq 0) { return "" }
  return [string]$reports[0].FullName
}

function Write-SessionReport {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$CulpritHistoryByJar,
    [Parameter(Mandatory = $true)]
    [hashtable]$CulpritCurrentByJar,
    [Parameter(Mandatory = $false)]
    [string]$CompatReportPath = "",
    [Parameter(Mandatory = $false)]
    [datetime]$SessionStartTime = [datetime]::MinValue,
    [Parameter(Mandatory = $false)]
    [hashtable]$RecoveredJarNames = @{},
    [Parameter(Mandatory = $false)]
    [array]$MixinConflicts = @()
  )

  Write-Host ""
  Write-Host "Session report" -ForegroundColor Cyan
  $endTime = Get-Date
  Write-Host ("End time: {0}" -f $endTime.ToString("yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
  if ($SessionStartTime -ne [datetime]::MinValue) {
    $elapsed = $endTime - $SessionStartTime
    $parts = @()
    if ($elapsed.Hours -gt 0) { $parts += ("{0}h" -f $elapsed.Hours) }
    if ($elapsed.Minutes -gt 0) { $parts += ("{0}m" -f $elapsed.Minutes) }
    $parts += ("{0}s" -f $elapsed.Seconds)
    Write-Host ("Elapsed: {0}" -f ($parts -join " ")) -ForegroundColor Gray
  }
  if (-not [string]::IsNullOrWhiteSpace($CompatReportPath)) {
    Write-Host ("Compatibility report: {0}" -f $CompatReportPath) -ForegroundColor Gray
  }

  $historyMoves = @($CulpritHistoryByJar.Values | Where-Object { $null -ne $_ })
  if (-not $historyMoves -or $historyMoves.Count -eq 0) {
    Write-Host "No culprits detected in this session." -ForegroundColor Green
  } else {
    # * Group culprits by stage for detailed report.
    $byStage = @{}
    foreach ($move in $historyMoves) {
      if ($null -eq $move) { continue }
      $jarName = [string]$move.JarName
      if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
      $stage = "unknown"
      if ($move | Get-Member -Name "Stage" -MemberType NoteProperty, Property) {
        $s = [string]$move.Stage
        if (-not [string]::IsNullOrWhiteSpace($s)) { $stage = $s }
      }
      if (-not $byStage.ContainsKey($stage)) { $byStage[$stage] = @() }
      $byStage[$stage] += @($move)
    }

    $uniqueMoves = @($historyMoves | Sort-Object -Property JarName -Unique)
    Write-Host ("Culprits detected: {0}" -f $uniqueMoves.Count) -ForegroundColor Yellow

    # * Display by stage.
    $stageLabels = @{
      "mixin-analysis" = "Mixin analysis"
      "layering"       = "Layering"
      "isolation"      = "Subtractive isolation"
      "recovery"       = "Recovery (root cause)"
      "unknown"        = "Other"
    }
    foreach ($stage in @("mixin-analysis", "layering", "isolation", "recovery", "unknown")) {
      if (-not $byStage.ContainsKey($stage)) { continue }
      $stageLabel = if ($stageLabels.ContainsKey($stage)) { $stageLabels[$stage] } else { $stage }
      $stageMoves = @($byStage[$stage])
      Write-Host ("  [{0}] ({1}):" -f $stageLabel, $stageMoves.Count) -ForegroundColor Gray
      foreach ($move in ($stageMoves | Sort-Object -Property JarName)) {
        $jarName = [string]$move.JarName
        $locations = New-Object System.Collections.Generic.List[string]
        $storagePath = [string]$move.StorageLegacyPath
        $gamePath = [string]$move.GameLegacyPath
        if (-not [string]::IsNullOrWhiteSpace($storagePath)) { $locations.Add(("storage: {0}" -f $storagePath)) }
        if (-not [string]::IsNullOrWhiteSpace($gamePath)) { $locations.Add(("game: {0}" -f $gamePath)) }
        $locationLabel = if ($locations.Count -gt 0) { $locations -join "; " } else { "location unknown" }
        Write-Host ("    - {0} ({1})" -f $jarName, $locationLabel) -ForegroundColor Gray
      }
    }
  }

  # * Show recovered (restored) mods from phantom culprit recovery.
  if ($RecoveredJarNames -and $RecoveredJarNames.Count -gt 0) {
    $recoveredNames = @($RecoveredJarNames.Values | Sort-Object -Unique)
    Write-Host ("Recovered (restored from false positive): {0}" -f $recoveredNames.Count) -ForegroundColor Green
    foreach ($rn in $recoveredNames) {
      Write-Host ("  + {0}" -f $rn) -ForegroundColor Green
    }
  }

  # * Show Mixin conflict info and developer notification recommendation.
  if ($MixinConflicts -and $MixinConflicts.Count -gt 0) {
    Write-Host ""
    Write-Host ("Mixin conflicts detected ({0}):" -f $MixinConflicts.Count) -ForegroundColor Cyan
    foreach ($conflict in $MixinConflicts) {
      $srcLabel = [string]$conflict.SourceModId
      $srcJar = [string]$conflict.SourceJar
      $tgtLabel = if (-not [string]::IsNullOrWhiteSpace([string]$conflict.TargetModId)) { [string]$conflict.TargetModId } else { [string]$conflict.TargetClass }
      $tgtJar = [string]$conflict.TargetJar
      $srcDisplay = if (-not [string]::IsNullOrWhiteSpace($srcJar)) { "{0} ({1})" -f $srcLabel, $srcJar } else { $srcLabel }
      $tgtDisplay = if (-not [string]::IsNullOrWhiteSpace($tgtJar)) { "{0} ({1})" -f $tgtLabel, $tgtJar } else { $tgtLabel }
      Write-Host ("  {0} → {1}" -f $srcDisplay, $tgtDisplay) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "Please report these incompatibilities to the developers of the affected mods" -ForegroundColor Yellow
    Write-Host "so they can fix the broken Mixin references in future updates." -ForegroundColor Yellow
  }

  $currentNames = @($CulpritCurrentByJar.Values |
      ForEach-Object { $_.JarName } |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
      Sort-Object -Unique)
  if ($currentNames -and $currentNames.Count -gt 0) {
    Write-Host ("Currently isolated mods: {0}" -f ($currentNames -join ", ")) -ForegroundColor Yellow
  }
}

try {
  if ($enableTranscript) {
    if (Test-Path -LiteralPath $transcriptLogPath) {
      Remove-Item -LiteralPath $transcriptLogPath -Force -ErrorAction Stop
    }
    Start-Transcript -Path $transcriptLogPath -Force | Out-Null
    $transcriptStarted = $true
  }

  # * Write session header to legacy.log (append-only, session-divided).
  $legacyLogPath = Join-Path -Path $PSScriptRoot -ChildPath "legacy.log"
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

$projectConfig = Import-ProjectConfig -StartDir $PSScriptRoot
if ($projectConfig.LoadedPaths -and $projectConfig.LoadedPaths.Count -gt 0) {
  Write-Verbose ("Config loaded: {0}" -f ($projectConfig.LoadedPaths -join ", "))
}
$configIni = $projectConfig.Ini

if (-not $PSBoundParameters.ContainsKey("LauncherExePath")) {
  $LauncherExePath = Get-IniValue -Ini $configIni -Section "Paths" -Key "LauncherExePath" -Default ""
}
if (-not $PSBoundParameters.ContainsKey("LogPath")) {
  $LogPath = Get-IniValue -Ini $configIni -Section "Paths" -Key "LogPath" -Default ""
}

$script:hashCacheGameModsDir = ""
$script:hashCachePath = ""
$script:hashCacheObject = $null
if (-not $DryRun -and $UseHashCache) {
  $defaultGameModsDir = Join-Path -Path ([Environment]::GetFolderPath('ApplicationData')) -ChildPath '.tlauncher\legacy\Minecraft\game\mods'
  $cfgGameModsDir = Get-IniValue -Ini $configIni -Section "Paths" -Key "GameModsDir" -Default ""
  $script:hashCacheGameModsDir = $(if (-not [string]::IsNullOrWhiteSpace($cfgGameModsDir)) { $cfgGameModsDir } else { $defaultGameModsDir })
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

if ([string]::IsNullOrWhiteSpace($CheckScriptPath)) {
  $CheckScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Check-Mod-Compatibility.ps1"
}

if (-not (Test-Path -LiteralPath $CheckScriptPath)) {
  throw ("Check script not found: {0}" -f $CheckScriptPath)
}

$effectiveIsolateOnNoChanges = ([bool]$IsolateOnNoChanges) -and (-not [bool]$DisableIsolationOnNoChanges)
if ($effectiveIsolateOnNoChanges) {
  if ([string]::IsNullOrWhiteSpace($IsolateScriptPath)) {
    $IsolateScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Isolate-Incompatible-Mod.ps1"
  }
  if (-not (Test-Path -LiteralPath $IsolateScriptPath)) {
    throw ("Isolation script not found: {0}" -f $IsolateScriptPath)
  }
}

# * Layering script: fallback strategy that adds mods in exponential batches.
$LayerScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Layer-Mods.ps1"
$layeringAvailable = Test-Path -LiteralPath $LayerScriptPath

# * Mixin analysis script: targeted Mixin error resolution (runs before layering).
$MixinAnalysisScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Analyze-MixinErrors.ps1"
$mixinAnalysisAvailable = Test-Path -LiteralPath $MixinAnalysisScriptPath

# * Recovery script: post-isolation phantom culprit recovery.
$RecoveryScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Recover-PhantomCulprits.ps1"
$recoveryAvailable = Test-Path -LiteralPath $RecoveryScriptPath

function Get-CompatibilityArg {
  $compatArgs = @()
  if ($DeleteFromGameMods) {
    $compatArgs += @("-DeleteFromGameMods")
  }
  if ($NoLegacy) {
    $compatArgs += @("-NoLegacy")
  }
  if ($GameLegacy) {
    $compatArgs += @("-GameLegacy")
  }
  if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
    $compatArgs += @("-LogPath", $LogPath)
  }
  if ($CheckScriptArguments) {
    foreach ($arg in $CheckScriptArguments) {
      if (-not [string]::IsNullOrWhiteSpace($arg)) {
        $compatArgs += @($arg)
      }
    }
  }
  # ! Use unary comma to prevent single-element unwrapping (avoids char-by-char splatting).
  return ,@($compatArgs)
}

function Get-IsolationExtraArg {
  $isolateExtraArgs = @()
  if ($IsolateScriptArguments) {
    foreach ($arg in $IsolateScriptArguments) {
      if (-not [string]::IsNullOrWhiteSpace($arg)) {
        $isolateExtraArgs += @($arg)
      }
    }
  }
  # ! Use unary comma to prevent single-element unwrapping (avoids char-by-char splatting).
  return ,@($isolateExtraArgs)
}

function Get-IsolationParam {
  param(
    [Parameter(Mandatory = $false)]
    [bool]$IncludeEmitResultObject = $false,
    [Parameter(Mandatory = $false)]
    [bool]$IncludeFastForward = $false,
    [Parameter(Mandatory = $false)]
    [bool]$IncludeKeepCulpritInGameLegacy = $false
  )

  $isolateParams = @{}
  if (-not [string]::IsNullOrWhiteSpace($LauncherExePath)) {
    $isolateParams["LauncherExePath"] = $LauncherExePath
  }
  if ($LauncherArguments -and $LauncherArguments.Count -gt 0) {
    $isolateParams["LauncherArguments"] = $LauncherArguments
  }
  if ($effectiveAutoLaunch) {
    $isolateParams["UseAutoLaunch"] = $true
  }
  if (-not [string]::IsNullOrWhiteSpace($LauncherWindowTitlePattern)) {
    $isolateParams["LauncherWindowTitlePattern"] = $LauncherWindowTitlePattern
  }
  if ($PlayButtonNames -and $PlayButtonNames.Count -gt 0) {
    $isolateParams["PlayButtonNames"] = $PlayButtonNames
  }
  if ($PlayClickOffsetX -ge 0) {
    $isolateParams["PlayClickOffsetX"] = $PlayClickOffsetX
  }
  if ($PlayClickOffsetY -ge 0) {
    $isolateParams["PlayClickOffsetY"] = $PlayClickOffsetY
  }
  if (-not $UseEnterFallback) {
    $isolateParams["UseEnterFallback"] = $false
  }
  if ($EnableBroadUiSearch) {
    $isolateParams["EnableBroadUiSearch"] = $true
  }
  if ($PrintCursorOffset) {
    $isolateParams["PrintCursorOffset"] = $true
  }
  if ($CrashWindowTitlePatterns -and $CrashWindowTitlePatterns.Count -gt 0) {
    $isolateParams["CrashWindowTitlePatterns"] = $CrashWindowTitlePatterns
  }
  if ($FabricWindowTitlePatterns -and $FabricWindowTitlePatterns.Count -gt 0) {
    $isolateParams["FabricWindowTitlePatterns"] = $FabricWindowTitlePatterns
  }
  if ($CrashCloseClickOffsetX -ge 0) {
    $isolateParams["CrashCloseClickOffsetX"] = $CrashCloseClickOffsetX
  }
  if ($CrashCloseClickOffsetY -ge 0) {
    $isolateParams["CrashCloseClickOffsetY"] = $CrashCloseClickOffsetY
  }
  if ($CrashCloseDelaySeconds -gt 0) {
    $isolateParams["CrashCloseDelaySeconds"] = $CrashCloseDelaySeconds
  }
  if ($UseLinearIsolation) {
    $isolateParams["UseLinearIsolation"] = $true
  }
  if ($BinaryLinearThreshold -gt 0) {
    $isolateParams["BinaryLinearThreshold"] = $BinaryLinearThreshold
  }
  if ($LauncherWindowTimeoutSeconds -gt 0) {
    $isolateParams["LauncherWindowTimeoutSeconds"] = $LauncherWindowTimeoutSeconds
  }
  if ($OutcomeTimeoutSeconds -gt 0) {
    $isolateParams["OutcomeTimeoutSeconds"] = $OutcomeTimeoutSeconds
  }
  if ($PollIntervalSeconds -gt 0) {
    $isolateParams["PollIntervalSeconds"] = $PollIntervalSeconds
  }
  if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
    $isolateParams["LogPath"] = $LogPath
  }
  if ($PSBoundParameters.ContainsKey("Verbose")) {
    $isolateParams["Verbose"] = $true
  }
  if ($IncludeKeepCulpritInGameLegacy -and $GameLegacy) {
    $isolateParams["KeepCulpritInGameLegacy"] = $true
  }
  if ($IncludeEmitResultObject) {
    $isolateParams["EmitResultObject"] = $true
  }
  if ($IncludeFastForward -and $sessionIsolationFastForwardJarNames -and $sessionIsolationFastForwardJarNames.Count -gt 0) {
    Write-Host ("Fast-forward isolation enabled (previously tested mods: {0})." -f $sessionIsolationFastForwardJarNames.Count) -ForegroundColor Gray
    $isolateParams["PreIsolateJarNames"] = $sessionIsolationFastForwardJarNames
    if (-not [string]::IsNullOrWhiteSpace($sessionIsolationFastForwardEvidenceKey)) {
      $isolateParams["PreIsolateBaselineEvidenceKey"] = $sessionIsolationFastForwardEvidenceKey
    }
  }

  $effectiveHashCache = ([bool]$UseHashCache) -and (-not [bool]$script:hashCacheDisabledThisSession)
  $isolateParams["UseHashCache"] = [bool]$effectiveHashCache
  if (-not [string]::IsNullOrWhiteSpace($HashCacheFileName)) { $isolateParams["HashCacheFileName"] = $HashCacheFileName }
  if ($HashCacheHashRetryCount -gt 0) { $isolateParams["HashCacheHashRetryCount"] = $HashCacheHashRetryCount }
  if ($HashCacheHashRetryDelayMs -ge 0) { $isolateParams["HashCacheHashRetryDelayMs"] = $HashCacheHashRetryDelayMs }
  return $isolateParams
}

function Get-LayeringParam {
  param(
    [Parameter(Mandatory = $false)]
    [bool]$IncludeEmitResultObject = $false,
    [Parameter(Mandatory = $false)]
    [bool]$IncludeKeepCulpritInGameLegacy = $false
  )

  $layerParams = @{}
  if (-not [string]::IsNullOrWhiteSpace($LauncherExePath)) {
    $layerParams["LauncherExePath"] = $LauncherExePath
  }
  if ($LauncherArguments -and $LauncherArguments.Count -gt 0) {
    $layerParams["LauncherArguments"] = $LauncherArguments
  }
  if ($effectiveAutoLaunch) {
    $layerParams["UseAutoLaunch"] = $true
  }
  if (-not [string]::IsNullOrWhiteSpace($LauncherWindowTitlePattern)) {
    $layerParams["LauncherWindowTitlePattern"] = $LauncherWindowTitlePattern
  }
  if ($PlayButtonNames -and $PlayButtonNames.Count -gt 0) {
    $layerParams["PlayButtonNames"] = $PlayButtonNames
  }
  if ($PlayClickOffsetX -ge 0) { $layerParams["PlayClickOffsetX"] = $PlayClickOffsetX }
  if ($PlayClickOffsetY -ge 0) { $layerParams["PlayClickOffsetY"] = $PlayClickOffsetY }
  if (-not $UseEnterFallback) { $layerParams["UseEnterFallback"] = $false }
  if ($EnableBroadUiSearch) { $layerParams["EnableBroadUiSearch"] = $true }
  if ($CrashWindowTitlePatterns -and $CrashWindowTitlePatterns.Count -gt 0) {
    $layerParams["CrashWindowTitlePatterns"] = $CrashWindowTitlePatterns
  }
  if ($FabricWindowTitlePatterns -and $FabricWindowTitlePatterns.Count -gt 0) {
    $layerParams["FabricWindowTitlePatterns"] = $FabricWindowTitlePatterns
  }
  if ($CrashCloseClickOffsetX -ge 0) { $layerParams["CrashCloseClickOffsetX"] = $CrashCloseClickOffsetX }
  if ($CrashCloseClickOffsetY -ge 0) { $layerParams["CrashCloseClickOffsetY"] = $CrashCloseClickOffsetY }
  if ($CrashCloseDelaySeconds -gt 0) { $layerParams["CrashCloseDelaySeconds"] = $CrashCloseDelaySeconds }
  if ($LauncherWindowTimeoutSeconds -gt 0) { $layerParams["LauncherWindowTimeoutSeconds"] = $LauncherWindowTimeoutSeconds }
  if ($script:OutcomeTimeoutSecondsBound -and $OutcomeTimeoutSeconds -gt 0) { $layerParams["OutcomeTimeoutSeconds"] = $OutcomeTimeoutSeconds }
  if ($PollIntervalSeconds -gt 0) { $layerParams["PollIntervalSeconds"] = $PollIntervalSeconds }
  if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $layerParams["LogPath"] = $LogPath }
  if ($PSBoundParameters.ContainsKey("Verbose")) { $layerParams["Verbose"] = $true }
  if ($IncludeKeepCulpritInGameLegacy -and $GameLegacy) {
    $layerParams["KeepCulpritInGameLegacy"] = $true
  }
  if ($ThoroughStabilityCheck) { $layerParams["ThoroughStabilityCheck"] = $true }
  if ($IncludeEmitResultObject) { $layerParams["EmitResultObject"] = $true }

  $effectiveHashCache = ([bool]$UseHashCache) -and (-not [bool]$script:hashCacheDisabledThisSession)
  $layerParams["UseHashCache"] = [bool]$effectiveHashCache
  if (-not [string]::IsNullOrWhiteSpace($HashCacheFileName)) { $layerParams["HashCacheFileName"] = $HashCacheFileName }
  if ($HashCacheHashRetryCount -gt 0) { $layerParams["HashCacheHashRetryCount"] = $HashCacheHashRetryCount }
  if ($HashCacheHashRetryDelayMs -ge 0) { $layerParams["HashCacheHashRetryDelayMs"] = $HashCacheHashRetryDelayMs }

  return $layerParams
}

function Get-MixinAnalysisParam {
  # * Builds parameter hashtable for Analyze-MixinErrors.ps1.
  $p = @{}
  if (-not [string]::IsNullOrWhiteSpace($LauncherExePath)) { $p["LauncherExePath"] = $LauncherExePath }
  if ($LauncherArguments -and $LauncherArguments.Count -gt 0) { $p["LauncherArguments"] = $LauncherArguments }
  if ($effectiveAutoLaunch) { $p["UseAutoLaunch"] = $true }
  if (-not [string]::IsNullOrWhiteSpace($LauncherWindowTitlePattern)) { $p["LauncherWindowTitlePattern"] = $LauncherWindowTitlePattern }
  if ($PlayButtonNames -and $PlayButtonNames.Count -gt 0) { $p["PlayButtonNames"] = $PlayButtonNames }
  if ($PlayClickOffsetX -ge 0) { $p["PlayClickOffsetX"] = $PlayClickOffsetX }
  if ($PlayClickOffsetY -ge 0) { $p["PlayClickOffsetY"] = $PlayClickOffsetY }
  if (-not $UseEnterFallback) { $p["UseEnterFallback"] = $false }
  if ($EnableBroadUiSearch) { $p["EnableBroadUiSearch"] = $true }
  if ($CrashWindowTitlePatterns -and $CrashWindowTitlePatterns.Count -gt 0) { $p["CrashWindowTitlePatterns"] = $CrashWindowTitlePatterns }
  if ($FabricWindowTitlePatterns -and $FabricWindowTitlePatterns.Count -gt 0) { $p["FabricWindowTitlePatterns"] = $FabricWindowTitlePatterns }
  if ($CrashCloseClickOffsetX -ge 0) { $p["CrashCloseClickOffsetX"] = $CrashCloseClickOffsetX }
  if ($CrashCloseClickOffsetY -ge 0) { $p["CrashCloseClickOffsetY"] = $CrashCloseClickOffsetY }
  if ($CrashCloseDelaySeconds -gt 0) { $p["CrashCloseDelaySeconds"] = $CrashCloseDelaySeconds }
  if ($LauncherWindowTimeoutSeconds -gt 0) { $p["LauncherWindowTimeoutSeconds"] = $LauncherWindowTimeoutSeconds }
  if ($script:OutcomeTimeoutSecondsBound -and $OutcomeTimeoutSeconds -gt 0) { $p["OutcomeTimeoutSeconds"] = $OutcomeTimeoutSeconds }
  if ($PollIntervalSeconds -gt 0) { $p["PollIntervalSeconds"] = $PollIntervalSeconds }
  if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $p["LogPath"] = $LogPath }
  if ($PSBoundParameters.ContainsKey("Verbose")) { $p["Verbose"] = $true }
  if ($GameLegacy) { $p["KeepCulpritInGameLegacy"] = $true }
  $p["EmitResultObject"] = $true
  return $p
}

function Get-RecoveryParam {
  # * Builds parameter hashtable for Recover-PhantomCulprits.ps1.
  $p = @{}
  if (-not [string]::IsNullOrWhiteSpace($LauncherExePath)) { $p["LauncherExePath"] = $LauncherExePath }
  if ($LauncherArguments -and $LauncherArguments.Count -gt 0) { $p["LauncherArguments"] = $LauncherArguments }
  if ($effectiveAutoLaunch) { $p["UseAutoLaunch"] = $true }
  if (-not [string]::IsNullOrWhiteSpace($LauncherWindowTitlePattern)) { $p["LauncherWindowTitlePattern"] = $LauncherWindowTitlePattern }
  if ($PlayButtonNames -and $PlayButtonNames.Count -gt 0) { $p["PlayButtonNames"] = $PlayButtonNames }
  if ($PlayClickOffsetX -ge 0) { $p["PlayClickOffsetX"] = $PlayClickOffsetX }
  if ($PlayClickOffsetY -ge 0) { $p["PlayClickOffsetY"] = $PlayClickOffsetY }
  if (-not $UseEnterFallback) { $p["UseEnterFallback"] = $false }
  if ($EnableBroadUiSearch) { $p["EnableBroadUiSearch"] = $true }
  if ($CrashWindowTitlePatterns -and $CrashWindowTitlePatterns.Count -gt 0) { $p["CrashWindowTitlePatterns"] = $CrashWindowTitlePatterns }
  if ($FabricWindowTitlePatterns -and $FabricWindowTitlePatterns.Count -gt 0) { $p["FabricWindowTitlePatterns"] = $FabricWindowTitlePatterns }
  if ($CrashCloseClickOffsetX -ge 0) { $p["CrashCloseClickOffsetX"] = $CrashCloseClickOffsetX }
  if ($CrashCloseClickOffsetY -ge 0) { $p["CrashCloseClickOffsetY"] = $CrashCloseClickOffsetY }
  if ($CrashCloseDelaySeconds -gt 0) { $p["CrashCloseDelaySeconds"] = $CrashCloseDelaySeconds }
  if ($LauncherWindowTimeoutSeconds -gt 0) { $p["LauncherWindowTimeoutSeconds"] = $LauncherWindowTimeoutSeconds }
  if ($script:OutcomeTimeoutSecondsBound -and $OutcomeTimeoutSeconds -gt 0) { $p["OutcomeTimeoutSeconds"] = $OutcomeTimeoutSeconds }
  if ($PollIntervalSeconds -gt 0) { $p["PollIntervalSeconds"] = $PollIntervalSeconds }
  if ($PSBoundParameters.ContainsKey("Verbose")) { $p["Verbose"] = $true }
  if ($GameLegacy) { $p["KeepCulpritInGameLegacy"] = $true }
  $p["DependencyMapSource"] = "File"
  $p["EmitResultObject"] = $true
  return $p
}

function Format-IsolationParamsForDisplay {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Params
  )

  $prettyParams = @()
  foreach ($key in ($Params.Keys | Sort-Object)) {
    $value = $Params[$key]
    if ($value -is [System.Array]) {
      $prettyParams += @(("-{0} [{1}]" -f $key, (($value | ForEach-Object { "'{0}'" -f $_ }) -join ", ")))
    } else {
      $prettyParams += @(("-{0} '{1}'" -f $key, $value))
    }
  }
  # ! Use unary comma to prevent single-element unwrapping (avoids char-by-char splatting).
  return ,@($prettyParams)
}

function Close-FabricDialogWindow {
  param(
    [Parameter(Mandatory = $true)]
    $Window,
    [Parameter(Mandatory = $true)]
    [bool]$IsDryRun
  )

  if ($null -eq $Window) { return }
  Write-Host "Closing Fabric Loader dialog." -ForegroundColor Gray
  if ($IsDryRun) {
    Write-Host "DRYRUN would close Fabric Loader dialog." -ForegroundColor Gray
    return
  }
  Invoke-WindowClose -Handle $Window.Handle
  Start-Sleep -Milliseconds 250
  [void][MCCompatWin32]::SetForegroundWindow($Window.Handle)
  Start-Sleep -Milliseconds 150
  [System.Windows.Forms.SendKeys]::SendWait("%{F4}")
}

function Select-UnknownGameWindow {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$CrashPatterns,
    [Parameter(Mandatory = $true)]
    [string[]]$FabricPatterns,
    [Parameter(Mandatory = $true)]
    [string[]]$GameProcessNames,
    [Parameter(Mandatory = $true)]
    [datetime]$LaunchStart
  )

  if (-not $GameProcessNames -or $GameProcessNames.Count -eq 0) { return $null }
  $recent = Get-RecentProcessesByName -Names $GameProcessNames -StartedAfter $LaunchStart
  if (-not $recent -or $recent.Count -eq 0) { return $null }

  $pidSet = @{}
  foreach ($p in $recent) {
    if ($null -eq $p) { continue }
    try {
      $pidSet[[int]$p.Id] = $true
    } catch {
      continue
    }
  }
  if ($pidSet.Count -eq 0) { return $null }

  $windows = Get-WindowList
  foreach ($window in $windows) {
    if ($null -eq $window) { continue }
    $processId = 0
    try {
      $processId = [int]$window.ProcessId
    } catch {
      continue
    }
    if (-not $pidSet.ContainsKey($processId)) { continue }

    $title = [string]$window.Title
    if ([string]::IsNullOrWhiteSpace($title)) { continue }

    $known = $false
    foreach ($pattern in $CrashPatterns) {
      if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
      if (Test-TitleMatch -Title $title -Pattern $pattern) { $known = $true; break }
    }
    if (-not $known) {
      foreach ($pattern in $FabricPatterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if (Test-TitleMatch -Title $title -Pattern $pattern) { $known = $true; break }
      }
    }
    if (-not $known -and (Test-TitleMatch -Title $title -Pattern "Minecraft")) { $known = $true }
    if ($known) { continue }

    return $window
  }

  return $null
}

function Test-ProcessLooksLikeMinecraftGame {
  param(
    [Parameter(Mandatory = $true)]
    $Process
  )

  if ($null -eq $Process) { return $false }
  $name = [string]$Process.Name
  if ([string]::IsNullOrWhiteSpace($name)) { return $false }
  $nameLower = $name.ToLowerInvariant()

  if ($nameLower -ne "java" -and $nameLower -ne "javaw") {
    return $true
  }

  $processId = 0
  try {
    $processId = [int]$Process.Id
  } catch {
    return $false
  }
  if ($processId -le 0) { return $false }

  try {
    $cim = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f $processId) -ErrorAction Stop -Verbose:$false
  } catch {
    return $false
  }
  if ($null -eq $cim) { return $false }

  $cmd = [string]$cim.CommandLine
  if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }

  return ($cmd -match "net\.minecraft")
}

function Stop-SessionGameProcess {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([int])]
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$GameProcessNames,
    [Parameter(Mandatory = $true)]
    [datetime]$StartedAfter
  )

  if (-not $GameProcessNames -or $GameProcessNames.Count -eq 0) { return 0 }
  $recent = Get-RecentProcessesByName -Names $GameProcessNames -StartedAfter $StartedAfter
  if (-not $recent -or $recent.Count -eq 0) { return 0 }

  $killed = 0
  foreach ($p in $recent) {
    if (-not (Test-ProcessLooksLikeMinecraftGame -Process $p)) { continue }
    $label = "{0} (pid {1})" -f $p.Name, $p.Id
    if (-not $PSCmdlet.ShouldProcess($label, "Kill game process")) { continue }
    try {
      Write-Host ("Stopping game process: {0}" -f $label) -ForegroundColor Gray
      $p.Kill()
      $killed++
    } catch {
      Write-Verbose ("Failed to kill process {0}: {1}" -f $label, $_.Exception.Message)
    }
  }

  if ($killed -gt 0) {
    Start-Sleep -Seconds 3
  }

  return $killed
}

function Test-WindowPresence {
  param(
    [Parameter(Mandatory = $true)]
    [long]$HandleId
  )

  if ($HandleId -eq 0) { return $false }
  $windows = Get-WindowList
  foreach ($window in $windows) {
    if ([long]$window.Handle.ToInt64() -eq $HandleId) {
      return $true
    }
  }
  return $false
}

function Request-UserToCloseUnknownWindow {
  param(
    [Parameter(Mandatory = $true)]
    [long]$HandleId,
    [Parameter(Mandatory = $false)]
    [string]$WindowTitle = ""
  )

  if ($HandleId -eq 0) { return }
  $label = if ([string]::IsNullOrWhiteSpace($WindowTitle)) { "неизвестное окно" } else { $WindowTitle }
  $message = "Обнаружено неизвестное окно. Пожалуйста, закройте его и продолжите.`nОкно: {0}" -f $label

  while (Test-WindowPresence -HandleId $HandleId) {
    [void][System.Windows.Forms.MessageBox]::Show(
      $message,
      "Требуется действие пользователя",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    Start-Sleep -Milliseconds 300
  }
}

function Wait-ForOutcome {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$CrashPatterns,
    [Parameter(Mandatory = $true)]
    [string[]]$FabricPatterns,
    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds,
    [Parameter(Mandatory = $true)]
    [int]$PollSeconds,
    [Parameter(Mandatory = $true)]
    [int]$GraceSeconds,
    [Parameter(Mandatory = $true)]
    [datetime]$LaunchStart,
    [Parameter(Mandatory = $false)]
    [string[]]$GameProcessNames = @(),
    [Parameter(Mandatory = $false)]
    [long[]]$IgnoreCrashHandleIds = @()
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $launchStableByGrace = $false

  while ((Get-Date) -lt $deadline) {
    $crashWindow = Select-WindowByTitlePattern -Patterns $CrashPatterns -ExcludeHandleIds $IgnoreCrashHandleIds
    if ($null -ne $crashWindow) {
      return [pscustomobject]@{ Type = "CrashDialog"; Window = $crashWindow }
    }

    $fabricWindow = Select-WindowByTitlePattern -Patterns $FabricPatterns
    if ($null -ne $fabricWindow) {
      return [pscustomobject]@{ Type = "FabricDialog"; Window = $fabricWindow }
    }

    if ($GraceSeconds -gt 0 -and $GameProcessNames -and $GameProcessNames.Count -gt 0) {
      $now = Get-Date
      $recent = Get-RecentProcessesByName -Names $GameProcessNames -StartedAfter $LaunchStart
      foreach ($p in $recent) {
        try {
          $startTime = $p.StartTime
        } catch {
          continue
        }
        if (($now - $startTime).TotalSeconds -ge $GraceSeconds) {
          # * Mark that launch appears stable enough, but do not end early.
          # * Continue observing until full TimeoutSeconds to catch late crashes.
          $launchStableByGrace = $true
          break
        }
      }
    }

    # * Only check unknown windows after we have evidence the game actually launched.
    if ($launchStableByGrace) {
      $unknownWindow = Select-UnknownGameWindow -CrashPatterns $CrashPatterns -FabricPatterns $FabricPatterns `
        -GameProcessNames $GameProcessNames -LaunchStart $LaunchStart
      if ($null -ne $unknownWindow) {
        return [pscustomobject]@{ Type = "UnknownWindow"; Window = $unknownWindow }
      }
    }

    Start-Sleep -Seconds $PollSeconds
  }

  $lateCrash = Select-WindowByTitlePattern -Patterns $CrashPatterns -ExcludeHandleIds $IgnoreCrashHandleIds
  if ($null -ne $lateCrash) {
    return [pscustomobject]@{ Type = "CrashDialog"; Window = $lateCrash }
  }
  $lateFabric = Select-WindowByTitlePattern -Patterns $FabricPatterns
  if ($null -ne $lateFabric) {
    return [pscustomobject]@{ Type = "FabricDialog"; Window = $lateFabric }
  }
  $unknownWindow = Select-UnknownGameWindow -CrashPatterns $CrashPatterns -FabricPatterns $FabricPatterns `
    -GameProcessNames $GameProcessNames -LaunchStart $LaunchStart
  if ($null -ne $unknownWindow) {
    return [pscustomobject]@{ Type = "UnknownWindow"; Window = $unknownWindow }
  }
  return [pscustomobject]@{ Type = "Timeout"; Window = $null }
}

function Restore-IsolationCulpritMod {
  <#
  .SYNOPSIS
  Restores mods isolated by Isolate-Incompatible-Mod.ps1 back to game/storage roots.

  .DESCRIPTION
  Best-effort restore intended for "stop by user choice" flows.
  - Moves storage legacy copy back to storage root (when available).
  - Restores game copy from game legacy if present; otherwise copies from storage (legacy or root).
  #>
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$CulpritMoves,
    [Parameter(Mandatory = $false)]
    [int]$Retries = 10,
    [Parameter(Mandatory = $false)]
    [int]$DelayMs = 750
  )

  function Invoke-WithRetry {
    param(
      [Parameter(Mandatory = $true)]
      [scriptblock]$Action,
      [int]$MaxRetries = $Retries,
      [int]$WaitMs = $DelayMs
    )
    for ($i = 0; $i -le $MaxRetries; $i++) {
      try {
        & $Action
        return $true
      } catch [System.IO.IOException] {
        if ($i -ge $MaxRetries) { throw }
        Start-Sleep -Milliseconds $WaitMs
        continue
      } catch {
        throw
      }
    }
    return $false
  }

  $hadFailures = $false
  foreach ($m in $CulpritMoves) {
    if ($null -eq $m) { continue }

    $jarName = [string]$m.JarName
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }

    $gameModsDir = [string]$m.GameModsDir
    $storageModsDir = [string]$m.StorageModsDir
    $storageLegacyPath = [string]$m.StorageLegacyPath
    $gameLegacyPath = [string]$m.GameLegacyPath

    $storageTarget = $null
    if (-not [string]::IsNullOrWhiteSpace($storageModsDir)) {
      $storageTarget = Join-Path -Path $storageModsDir -ChildPath $jarName
    }
    $gameTarget = $null
    if (-not [string]::IsNullOrWhiteSpace($gameModsDir)) {
      $gameTarget = Join-Path -Path $gameModsDir -ChildPath $jarName
    }

    try {
      # * Restore storage first.
      if (-not [string]::IsNullOrWhiteSpace($storageLegacyPath) -and $storageTarget) {
        if (Test-Path -LiteralPath $storageLegacyPath) {
          if (Test-Path -LiteralPath $storageTarget) {
            Write-Host ("Warning: storage target already exists, leaving legacy copy: {0}" -f $storageTarget) -ForegroundColor Yellow
          } else {
            Invoke-WithRetry -Action { Move-Item -LiteralPath $storageLegacyPath -Destination $storageTarget -Force -ErrorAction Stop } -MaxRetries $Retries -WaitMs $DelayMs | Out-Null
            Write-Host ("Restored storage mod: {0}" -f $storageTarget) -ForegroundColor Green
          }
        }
      }

      # * Restore game mod (prefer game-legacy copy if present).
      if ($gameTarget) {
        if (Test-Path -LiteralPath $gameTarget) {
          # * Already restored (manually or by other logic).
          continue
        }

        if (-not [string]::IsNullOrWhiteSpace($gameLegacyPath) -and (Test-Path -LiteralPath $gameLegacyPath)) {
          Invoke-WithRetry -Action { Move-Item -LiteralPath $gameLegacyPath -Destination $gameTarget -Force -ErrorAction Stop } -MaxRetries $Retries -WaitMs $DelayMs | Out-Null
          Write-Host ("Restored game mod: {0}" -f $gameTarget) -ForegroundColor Green
          continue
        }

        # * Fallback: copy from storage root (preferred) or from storage legacy.
        if ($storageTarget -and (Test-Path -LiteralPath $storageTarget)) {
          Invoke-WithRetry -Action { Copy-Item -LiteralPath $storageTarget -Destination $gameTarget -Force -ErrorAction Stop } -MaxRetries $Retries -WaitMs $DelayMs | Out-Null
          Write-Host ("Restored game mod (copied from storage): {0}" -f $gameTarget) -ForegroundColor Green
          continue
        }
        if (-not [string]::IsNullOrWhiteSpace($storageLegacyPath) -and (Test-Path -LiteralPath $storageLegacyPath)) {
          Invoke-WithRetry -Action { Copy-Item -LiteralPath $storageLegacyPath -Destination $gameTarget -Force -ErrorAction Stop } -MaxRetries $Retries -WaitMs $DelayMs | Out-Null
          Write-Host ("Restored game mod (copied from storage legacy): {0}" -f $gameTarget) -ForegroundColor Green
          continue
        }

        Write-Host ("Warning: could not restore game mod '{0}' (no legacy/source copy found)." -f $jarName) -ForegroundColor Yellow
      }
    } catch {
      $hadFailures = $true
      Write-Host ("Error while restoring '{0}': {1}" -f $jarName, $_.Exception.Message) -ForegroundColor Red
    }
  }

  return (-not $hadFailures)
}

Write-Host ("Launcher title pattern: {0}" -f $LauncherWindowTitlePattern) -ForegroundColor Cyan
Write-Host "Attempt limit: unlimited" -ForegroundColor Gray
$launcherWindow = $null
$lastCrashDialogHandleId = 0

# * Capture click offsets from current cursor position once, before the run, if not provided.
if (($PlayClickOffsetX -lt 0 -or $PlayClickOffsetY -lt 0) -or $PrintCursorOffset) {
  $launcherWindow = Start-LauncherIfNeeded -TitlePattern $LauncherWindowTitlePattern `
    -ExePath $LauncherExePath `
    -ExeArguments $LauncherArguments `
    -AppendAutoLaunch $effectiveAutoLaunch `
    -TimeoutSeconds $LauncherWindowTimeoutSeconds `
    -IsDryRun ([bool]$DryRun) `
    -ShowWaitMessage $true
  while ($null -eq $launcherWindow) {
    Write-Host ("Launcher window not found. Waiting {0}s..." -f $PollIntervalSeconds) -ForegroundColor Yellow
    Start-Sleep -Seconds $PollIntervalSeconds
    $launcherWindow = Start-LauncherIfNeeded -TitlePattern $LauncherWindowTitlePattern `
      -ExePath $LauncherExePath `
      -ExeArguments $LauncherArguments `
      -AppendAutoLaunch $effectiveAutoLaunch `
      -TimeoutSeconds $LauncherWindowTimeoutSeconds `
      -IsDryRun ([bool]$DryRun) `
      -ShowWaitMessage $true
  }
  [void][MCCompatWin32]::SetForegroundWindow($launcherWindow.Handle)
  Start-Sleep -Milliseconds 150

  $offsets = Get-CursorOffsetRelativeToWindow -Handle $launcherWindow.Handle
  Write-Host ("Captured cursor offsets: X={0}, Y={1}" -f $offsets.OffsetX, $offsets.OffsetY) -ForegroundColor Gray
  if ($PlayClickOffsetX -lt 0 -or $PlayClickOffsetY -lt 0) {
    $PlayClickOffsetX = $offsets.OffsetX
    $PlayClickOffsetY = $offsets.OffsetY
    Write-Host ("Using captured offsets for Play click: X={0}, Y={1}" -f $PlayClickOffsetX, $PlayClickOffsetY) -ForegroundColor Cyan
  } else {
    Write-Host ("Using provided Play click offsets: X={0}, Y={1}" -f $PlayClickOffsetX, $PlayClickOffsetY) -ForegroundColor Cyan
  }
}

$sessionIsolationFastForwardJarNames = @()
$sessionIsolationFastForwardEvidenceKey = ""
$sessionIsolationCulpritByJar = @{}
$sessionIsolationCulpritHistoryByJar = @{}

$attempt = 0
while ($true) {
  $attempt++
  Write-Host ("Attempt {0}" -f $attempt) -ForegroundColor Cyan

  $launcherWindow = Start-LauncherIfNeeded -TitlePattern $LauncherWindowTitlePattern `
    -ExePath $LauncherExePath `
    -ExeArguments $LauncherArguments `
    -AppendAutoLaunch $effectiveAutoLaunch `
    -TimeoutSeconds $LauncherWindowTimeoutSeconds `
    -IsDryRun ([bool]$DryRun) `
    -ShowWaitMessage $true
  if ($null -eq $launcherWindow) {
    $answer = Read-Host "Лаунчер не найден. Продолжить попытки? (y/n)"
    if ($answer -notmatch "^(y|yes|д|да)$") {
      Write-Host "Stopping by user choice." -ForegroundColor Yellow
      exit 0
    }
    Write-Host ("Retrying in {0}s." -f $PollIntervalSeconds) -ForegroundColor Yellow
    Start-Sleep -Seconds $PollIntervalSeconds
    continue
  }
  Invoke-LauncherPlay -LauncherHandle $launcherWindow.Handle `
    -ButtonNames $PlayButtonNames `
    -ClickOffsetX $PlayClickOffsetX `
    -ClickOffsetY $PlayClickOffsetY `
    -EnableEnterFallback $UseEnterFallback `
    -AllowBroadSearch ([bool]$EnableBroadUiSearch) `
    -IsDryRun ([bool]$DryRun)

  $launchStart = Get-Date
  $ignoreCrashIds = @()
  if ($lastCrashDialogHandleId -ne 0) {
    $ignoreCrashIds = @($lastCrashDialogHandleId)
  }
  $outcome = Wait-ForOutcome -CrashPatterns $CrashWindowTitlePatterns `
    -FabricPatterns $FabricWindowTitlePatterns `
    -TimeoutSeconds $OutcomeTimeoutSeconds `
    -PollSeconds $PollIntervalSeconds `
    -GraceSeconds $SuccessGraceSeconds `
    -LaunchStart $launchStart `
    -GameProcessNames $GameProcessNames `
    -IgnoreCrashHandleIds $ignoreCrashIds

  # * Race guard: a crash/fabric dialog can appear right after Wait-ForOutcome returns.
  # * Re-check once before branching into outcome handling.
  if ($outcome.Type -eq "Timeout") {
    Start-Sleep -Milliseconds 600
    $lateCrashNow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns -ExcludeHandleIds $ignoreCrashIds
    if ($null -ne $lateCrashNow) {
      Write-Host ("Late crash dialog detected after probe window: {0}" -f $lateCrashNow.Title) -ForegroundColor Yellow
      $outcome = [pscustomobject]@{ Type = "CrashDialog"; Window = $lateCrashNow }
    } else {
      $lateFabricNow = Select-WindowByTitlePattern -Patterns $FabricWindowTitlePatterns
      if ($null -ne $lateFabricNow) {
        Write-Host ("Late Fabric dialog detected after probe window: {0}" -f $lateFabricNow.Title) -ForegroundColor Yellow
        $outcome = [pscustomobject]@{ Type = "FabricDialog"; Window = $lateFabricNow }
      }
    }
  }

  if ($outcome.Type -eq "CrashDialog") {
    Write-Host "Outcome: crash dialog detected. Running compatibility cleanup." -ForegroundColor Yellow

    # * Ensure the game is fully closed before any mod file operations.
    # * Without this, layering/isolation can hit file locks in initial quarantine.
    if (-not $DryRun) {
      $closedBeforeCleanup = Stop-SessionGameProcess -GameProcessNames $GameProcessNames -StartedAfter $sessionStartTime
      if ($closedBeforeCleanup -gt 0) {
        Write-Host ("Closed {0} running game process(es) before cleanup." -f $closedBeforeCleanup) -ForegroundColor Gray
      }
    }

    if (([bool]$UseHashCache) -and $script:hashCacheAttemptedThisSession -and (-not $script:hashCacheDisabledThisSession)) {
      Write-Host "Hash cache did not resolve the crash in this session. Retrying without hashes." -ForegroundColor Yellow
      $script:hashCacheDisabledThisSession = $true
    }

    if (-not $DryRun) {
      $compatArgs = Get-CompatibilityArg
      $forwardVerbose = [bool]$PSBoundParameters.ContainsKey("Verbose")
      $hasVerboseArg = $false
      foreach ($arg in $compatArgs) {
        if ($arg -ieq "-Verbose") { $hasVerboseArg = $true; break }
      }
      if ($hasVerboseArg) {
        & $CheckScriptPath @compatArgs
      } else {
        & $CheckScriptPath @compatArgs -Verbose:$forwardVerbose
      }
      $compatExitCode = $LASTEXITCODE
      if ($compatExitCode -ne 0) {
        if ($compatExitCode -eq 3) {
          if ($effectiveIsolateOnNoChanges) {
            # * Step 1: Try targeted Mixin analysis before heavy isolation.
            $ranMixinAnalysis = $false
            $mixinResolved = $false
            if ($mixinAnalysisAvailable) {
              Write-Host "Compatibility cleanup made no changes. Trying Mixin error analysis." -ForegroundColor Cyan
              $mixinParams = Get-MixinAnalysisParam
              $mixinResult = $null
              $mixinExitCode = 1
              try {
                $mixinResult = & $MixinAnalysisScriptPath @mixinParams
                $mixinExitCode = $LASTEXITCODE
              } catch [System.Management.Automation.PipelineStoppedException] {
                $sessionInterrupted = $true
                Write-Host "Mixin analysis interrupted by user (Ctrl+C)." -ForegroundColor Yellow
              } catch {
                Write-Host ("Warning: Mixin analysis failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
              }
              $ranMixinAnalysis = $true

              $mixinResultObj = $mixinResult
              if ($mixinResultObj -is [System.Array]) {
                if ($mixinResultObj.Count -gt 0) { $mixinResultObj = $mixinResultObj[$mixinResultObj.Count - 1] }
                else { $mixinResultObj = $null }
              }
              if ($null -ne $mixinResultObj -and ($mixinResultObj | Get-Member -Name "Type" -MemberType NoteProperty, Property)) {
                # * Collect Mixin conflict info regardless of resolution outcome.
                if ($mixinResultObj.Type -eq "MixinAnalysisResult" -and ($mixinResultObj | Get-Member -Name "MixinConflicts" -MemberType NoteProperty, Property)) {
                  $conflicts = @($mixinResultObj.MixinConflicts)
                  if ($conflicts.Count -gt 0) {
                    $sessionMixinConflicts = @($conflicts)
                  }
                }

                if ($mixinResultObj.Type -eq "MixinAnalysisResult" -and $mixinResultObj.Resolved) {
                  foreach ($move in @($mixinResultObj.CulpritMoves)) {
                    if ($null -eq $move) { continue }
                    $name = [string]$move.JarName
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }
                    $sessionIsolationCulpritByJar[$name.ToLowerInvariant()] = $move
                    $sessionIsolationCulpritHistoryByJar[$name.ToLowerInvariant()] = $move
                  }
                  $mixinResolved = $true
                  Write-Host "Mixin analysis resolved the crash. Returning to main loop." -ForegroundColor Cyan
                  Start-Sleep -Seconds 2
                  continue
                }
              }
              if (-not $mixinResolved -and $ranMixinAnalysis) {
                Write-Host ("Mixin analysis did not resolve (exit {0}). Proceeding to layering." -f $mixinExitCode) -ForegroundColor Gray
              }
            }

            # * Step 2: Try layering (additive strategy), then fall back to subtractive isolation.
            $ranLayering = $false
            if ($layeringAvailable) {
              Write-Host "Running layering strategy." -ForegroundColor Cyan
              $layerParams = Get-LayeringParam -IncludeEmitResultObject $true -IncludeKeepCulpritInGameLegacy $true
              $usedHashCacheNow = $false
              if ($layerParams.ContainsKey("UseHashCache")) {
                $usedHashCacheNow = [bool]$layerParams["UseHashCache"]
              }
              if ($usedHashCacheNow) { $script:hashCacheAttemptedThisSession = $true }

              $layeringResult = $null
              $layerExitCode = 1
              try {
                $layeringResult = & $LayerScriptPath @layerParams
                $layerExitCode = $LASTEXITCODE
              } catch [System.Management.Automation.PipelineStoppedException] {
                $sessionInterrupted = $true
                Write-Host "Layering interrupted by user (Ctrl+C)." -ForegroundColor Yellow
                $layerExitCode = 1
              } catch {
                Write-Host ("Warning: layering failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                $layerExitCode = 1
              }
              $ranLayering = $true

              $layeringResultObj = $layeringResult
              if ($layeringResultObj -is [System.Array]) {
                if ($layeringResultObj.Count -gt 0) {
                  $layeringResultObj = $layeringResultObj[$layeringResultObj.Count - 1]
                } else {
                  $layeringResultObj = $null
                }
              }
              $layerCulpritCount = 0
              $layerSkippedCount = 0
              if ($null -ne $layeringResultObj -and ($layeringResultObj | Get-Member -Name "Type" -MemberType NoteProperty, Property)) {
                if ($layeringResultObj.Type -eq "LayeringResult") {
                  try {
                    $layerSkippedCount = @($layeringResultObj.HashCacheSkippedJarNames).Count
                  } catch {
                    $layerSkippedCount = 0
                  }
                  foreach ($move in @($layeringResultObj.CulpritMoves)) {
                    if ($null -eq $move) { continue }
                    $name = [string]$move.JarName
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }
                    $sessionIsolationCulpritByJar[$name.ToLowerInvariant()] = $move
                    $sessionIsolationCulpritHistoryByJar[$name.ToLowerInvariant()] = $move
                    $layerCulpritCount++
                  }
                  if ($layerCulpritCount -eq 0) {
                    foreach ($name in @($layeringResultObj.CulpritJarNames)) {
                      $n = [string]$name
                      if ([string]::IsNullOrWhiteSpace($n)) { continue }
                      $move = [pscustomobject]@{
                        JarName = $n
                        GameModsDir = [string]$layeringResultObj.GameModsDir
                        StorageModsDir = [string]$layeringResultObj.StorageModsDir
                        StorageLegacyPath = ""
                        GameLegacyPath = ""
                        Minecraft = [string]$layeringResultObj.Minecraft
                        KeepCulpritInGameLegacy = $true
                        CrashEvidenceKey = ""
                        Stage = "layering"
                      }
                      $sessionIsolationCulpritByJar[$n.ToLowerInvariant()] = $move
                      $sessionIsolationCulpritHistoryByJar[$n.ToLowerInvariant()] = $move
                      $layerCulpritCount++
                    }
                  }
                }
              }

              if ($usedHashCacheNow -and $layerExitCode -eq 0 -and $layerCulpritCount -eq 0 -and $layerSkippedCount -gt 0) {
                Write-Host "Layering with hash cache skipped mods but found no culprits. Retrying without hashes." -ForegroundColor Yellow
                $script:hashCacheDisabledThisSession = $true

                $layerParams = Get-LayeringParam -IncludeEmitResultObject $true -IncludeKeepCulpritInGameLegacy $true
                $usedHashCacheNow = $false

                $layeringResult = $null
                $layerExitCode = 1
                try {
                  $layeringResult = & $LayerScriptPath @layerParams
                  $layerExitCode = $LASTEXITCODE
                } catch [System.Management.Automation.PipelineStoppedException] {
                  $sessionInterrupted = $true
                  Write-Host "Layering retry interrupted by user (Ctrl+C)." -ForegroundColor Yellow
                  $layerExitCode = 1
                } catch {
                  Write-Host ("Warning: layering retry failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                  $layerExitCode = 1
                }

                $layeringResultObj = $layeringResult
                if ($layeringResultObj -is [System.Array]) {
                  if ($layeringResultObj.Count -gt 0) {
                    $layeringResultObj = $layeringResultObj[$layeringResultObj.Count - 1]
                  } else {
                    $layeringResultObj = $null
                  }
                }

                if ($null -ne $layeringResultObj -and ($layeringResultObj | Get-Member -Name "Type" -MemberType NoteProperty, Property)) {
                  if ($layeringResultObj.Type -eq "LayeringResult") {
                    foreach ($move in @($layeringResultObj.CulpritMoves)) {
                      if ($null -eq $move) { continue }
                      $name = [string]$move.JarName
                      if ([string]::IsNullOrWhiteSpace($name)) { continue }
                      $sessionIsolationCulpritByJar[$name.ToLowerInvariant()] = $move
                      $sessionIsolationCulpritHistoryByJar[$name.ToLowerInvariant()] = $move
                    }
                    foreach ($name in @($layeringResultObj.CulpritJarNames)) {
                      $n = [string]$name
                      if ([string]::IsNullOrWhiteSpace($n)) { continue }
                      if ($sessionIsolationCulpritHistoryByJar.ContainsKey($n.ToLowerInvariant())) { continue }
                      $move = [pscustomobject]@{
                        JarName = $n
                        GameModsDir = [string]$layeringResultObj.GameModsDir
                        StorageModsDir = [string]$layeringResultObj.StorageModsDir
                        StorageLegacyPath = ""
                        GameLegacyPath = ""
                        Minecraft = [string]$layeringResultObj.Minecraft
                        KeepCulpritInGameLegacy = $true
                        CrashEvidenceKey = ""
                        Stage = "layering"
                      }
                      $sessionIsolationCulpritByJar[$n.ToLowerInvariant()] = $move
                      $sessionIsolationCulpritHistoryByJar[$n.ToLowerInvariant()] = $move
                    }
                  }
                }
              }

              if ($layerExitCode -eq 0) {
                # * Ensure no game instance survives layering before recovery/main-loop continuation.
                if (-not $DryRun) {
                  $closedAfterLayering = Stop-SessionGameProcess -GameProcessNames $GameProcessNames -StartedAfter $sessionStartTime
                  if ($closedAfterLayering -gt 0) {
                    Write-Host ("Closed {0} running game process(es) before post-layer actions." -f $closedAfterLayering) -ForegroundColor Gray
                  }
                }

                # * Step 3: Recovery — try to restore phantom culprits.
                if ($recoveryAvailable -and $sessionIsolationCulpritHistoryByJar.Count -ge 3) {
                  Write-Host "Running phantom culprit recovery analysis." -ForegroundColor Cyan
                  $recParams = Get-RecoveryParam
                  $culpritDataForRecovery = @($sessionIsolationCulpritHistoryByJar.Values | ForEach-Object {
                      [pscustomobject]@{
                        JarName = [string]$_.JarName
                        CrashEvidenceKey = if ($_ | Get-Member -Name "CrashEvidenceKey" -MemberType NoteProperty, Property) { [string]$_.CrashEvidenceKey } else { "" }
                        StorageLegacyPath = [string]$_.StorageLegacyPath
                        GameLegacyPath = [string]$_.GameLegacyPath
                      }
                    })
                  $recParams["CulpritDataJson"] = ($culpritDataForRecovery | ConvertTo-Json -Compress -Depth 5)
                  $firstCulpritMove = $sessionIsolationCulpritHistoryByJar.Values | Select-Object -First 1
                  if ($null -ne $firstCulpritMove) {
                    $recParams["Minecraft"] = if ($firstCulpritMove | Get-Member -Name "Minecraft" -MemberType NoteProperty, Property) { [string]$firstCulpritMove.Minecraft } else { "unknown" }
                  }
                  try {
                    $recResult = & $RecoveryScriptPath @recParams
                    $recObj = $recResult
                    if ($recObj -is [System.Array] -and $recObj.Count -gt 0) { $recObj = $recObj[$recObj.Count - 1] }
                    if ($null -ne $recObj -and ($recObj | Get-Member -Name "Type" -MemberType NoteProperty, Property) -and $recObj.Type -eq "RecoveryResult") {
                      foreach ($restored in @($recObj.RestoredJarNames)) {
                        $rk = [string]$restored
                        if (-not [string]::IsNullOrWhiteSpace($rk)) {
                          $sessionIsolationCulpritByJar.Remove($rk.ToLowerInvariant())
                          $sessionIsolationCulpritHistoryByJar.Remove($rk.ToLowerInvariant())
                          $sessionRecoveredJarNames[$rk.ToLowerInvariant()] = $rk
                        }
                      }
                      foreach ($newCulprit in @($recObj.NewCulpritJarNames)) {
                        $nk = [string]$newCulprit
                        if ([string]::IsNullOrWhiteSpace($nk)) { continue }
                        $move = [pscustomobject]@{
                          JarName = $nk; GameModsDir = ""; StorageModsDir = ""; StorageLegacyPath = ""
                          GameLegacyPath = ""; Minecraft = ""; KeepCulpritInGameLegacy = $true
                          CrashEvidenceKey = ""; Stage = "recovery"
                        }
                        $sessionIsolationCulpritByJar[$nk.ToLowerInvariant()] = $move
                        $sessionIsolationCulpritHistoryByJar[$nk.ToLowerInvariant()] = $move
                      }
                    }
                  } catch {
                    Write-Host ("Warning: recovery failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                  }
                }
                Write-Host "Layering completed. Returning to main loop." -ForegroundColor Cyan
                Start-Sleep -Seconds 2
                continue
              }
              if ($layerExitCode -eq 130) {
                Write-Host "Launcher start canceled by user during layering. Stopping by user choice." -ForegroundColor Yellow
                exit 0
              }
              Write-Host ("Layering finished with exit code {0}. Falling back to isolation." -f $layerExitCode) -ForegroundColor Yellow
            }

            if (-not $ranLayering -or $layerExitCode -ne 0) {
              Write-Host "Running subtractive isolation." -ForegroundColor Cyan
              $isolateParams = Get-IsolationParam -IncludeEmitResultObject $true -IncludeFastForward $true -IncludeKeepCulpritInGameLegacy $true
              $usedHashCacheNow = $false
              if ($isolateParams.ContainsKey("UseHashCache")) {
                $usedHashCacheNow = [bool]$isolateParams["UseHashCache"]
              }
              if ($usedHashCacheNow) { $script:hashCacheAttemptedThisSession = $true }

              $isolateExtraArgs = Get-IsolationExtraArg

              $isolationResult = $null
              $isolateExitCode = 1
              try {
                $isolationResult = & $IsolateScriptPath @isolateParams @isolateExtraArgs
                $isolateExitCode = $LASTEXITCODE
              } catch [System.Management.Automation.PipelineStoppedException] {
                $sessionInterrupted = $true
                Write-Host "Isolation interrupted by user (Ctrl+C)." -ForegroundColor Yellow
                $isolateExitCode = 1
              } catch {
                Write-Host ("Warning: isolation failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                $isolateExitCode = 1
              }

              $isolationResultObj = $isolationResult
              if ($isolationResultObj -is [System.Array]) {
                if ($isolationResultObj.Count -gt 0) {
                  $isolationResultObj = $isolationResultObj[$isolationResultObj.Count - 1]
                } else {
                  $isolationResultObj = $null
                }
              }

              $isolateSkippedCount = 0
              $isolateCulpritCount = 0
              if ($null -ne $isolationResultObj -and ($isolationResultObj | Get-Member -Name "Type" -MemberType NoteProperty, Property)) {
                if ($isolationResultObj.Type -eq "IsolationResult") {
                  try {
                    $isolateSkippedCount = @($isolationResultObj.HashCacheSkippedJarNames).Count
                  } catch {
                    $isolateSkippedCount = 0
                  }
                  $sessionIsolationFastForwardJarNames = @($isolationResultObj.FastForwardJarNames)
                  $sessionIsolationFastForwardEvidenceKey = [string]$isolationResultObj.BaselineEvidenceKey
                  foreach ($move in @($isolationResultObj.CulpritMoves)) {
                    if ($null -eq $move) { continue }
                    $name = [string]$move.JarName
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }
                    $sessionIsolationCulpritByJar[$name.ToLowerInvariant()] = $move
                    $sessionIsolationCulpritHistoryByJar[$name.ToLowerInvariant()] = $move
                    $isolateCulpritCount++
                  }
                  if ($isolateCulpritCount -eq 0) {
                    foreach ($name in @($isolationResultObj.CulpritJarNames)) {
                      $n = [string]$name
                      if ([string]::IsNullOrWhiteSpace($n)) { continue }
                      $move = [pscustomobject]@{
                        JarName = $n
                        GameModsDir = [string]$isolationResultObj.GameModsDir
                        StorageModsDir = [string]$isolationResultObj.StorageModsDir
                        StorageLegacyPath = ""
                        GameLegacyPath = ""
                        Minecraft = [string]$isolationResultObj.Minecraft
                        KeepCulpritInGameLegacy = $true
                        CrashEvidenceKey = ""
                        Stage = "isolation"
                      }
                      $sessionIsolationCulpritByJar[$n.ToLowerInvariant()] = $move
                      $sessionIsolationCulpritHistoryByJar[$n.ToLowerInvariant()] = $move
                      $isolateCulpritCount++
                    }
                  }
                }
              }

              if ($isolateExitCode -ne 0 -and $usedHashCacheNow -and $isolateSkippedCount -gt 0) {
                Write-Host "Isolation with hash cache skipped mods but did not succeed. Retrying without hashes." -ForegroundColor Yellow
                $script:hashCacheDisabledThisSession = $true

                $isolateParams = Get-IsolationParam -IncludeEmitResultObject $true -IncludeFastForward $true -IncludeKeepCulpritInGameLegacy $true
                $usedHashCacheNow = $false

                $isolationResult = $null
                $isolateExitCode = 1
                try {
                  $isolationResult = & $IsolateScriptPath @isolateParams @isolateExtraArgs
                  $isolateExitCode = $LASTEXITCODE
                } catch [System.Management.Automation.PipelineStoppedException] {
                  $sessionInterrupted = $true
                  Write-Host "Isolation retry interrupted by user (Ctrl+C)." -ForegroundColor Yellow
                  $isolateExitCode = 1
                } catch {
                  Write-Host ("Warning: isolation retry failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                  $isolateExitCode = 1
                }

                $isolationResultObj = $isolationResult
                if ($isolationResultObj -is [System.Array]) {
                  if ($isolationResultObj.Count -gt 0) {
                    $isolationResultObj = $isolationResultObj[$isolationResultObj.Count - 1]
                  } else {
                    $isolationResultObj = $null
                  }
                }

                if ($null -ne $isolationResultObj -and ($isolationResultObj | Get-Member -Name "Type" -MemberType NoteProperty, Property)) {
                  if ($isolationResultObj.Type -eq "IsolationResult") {
                    $sessionIsolationFastForwardJarNames = @($isolationResultObj.FastForwardJarNames)
                    $sessionIsolationFastForwardEvidenceKey = [string]$isolationResultObj.BaselineEvidenceKey
                    foreach ($move in @($isolationResultObj.CulpritMoves)) {
                      if ($null -eq $move) { continue }
                      $name = [string]$move.JarName
                      if ([string]::IsNullOrWhiteSpace($name)) { continue }
                      $sessionIsolationCulpritByJar[$name.ToLowerInvariant()] = $move
                      $sessionIsolationCulpritHistoryByJar[$name.ToLowerInvariant()] = $move
                    }
                    foreach ($name in @($isolationResultObj.CulpritJarNames)) {
                      $n = [string]$name
                      if ([string]::IsNullOrWhiteSpace($n)) { continue }
                      if ($sessionIsolationCulpritHistoryByJar.ContainsKey($n.ToLowerInvariant())) { continue }
                      $move = [pscustomobject]@{
                        JarName = $n
                        GameModsDir = [string]$isolationResultObj.GameModsDir
                        StorageModsDir = [string]$isolationResultObj.StorageModsDir
                        StorageLegacyPath = ""
                        GameLegacyPath = ""
                        Minecraft = [string]$isolationResultObj.Minecraft
                        KeepCulpritInGameLegacy = $true
                        CrashEvidenceKey = ""
                        Stage = "isolation"
                      }
                      $sessionIsolationCulpritByJar[$n.ToLowerInvariant()] = $move
                      $sessionIsolationCulpritHistoryByJar[$n.ToLowerInvariant()] = $move
                    }
                  }
                }
              }

              if ($isolateExitCode -eq 130) {
                Write-Host "Launcher start canceled by user during isolation. Stopping by user choice." -ForegroundColor Yellow
                exit 0
              }

              if ($isolateExitCode -ne 0) {
                Write-Host ("Isolation failed with exit code {0}. Stopping." -f $isolateExitCode) -ForegroundColor Red
                exit $isolateExitCode
              }

              Write-Host "Isolation completed. Returning to main loop." -ForegroundColor Cyan
              Start-Sleep -Seconds 2
              continue
            }
          }
          Write-Host "Compatibility cleanup made no changes. Stopping to avoid a loop." -ForegroundColor Yellow
          exit 3
        }
        Write-Host ("Compatibility cleanup failed with exit code {0}. Stopping." -f $compatExitCode) -ForegroundColor Red
        exit $compatExitCode
      }
    } else {
      $compatArgs = Get-CompatibilityArg
      if ($compatArgs.Count -gt 0) {
        Write-Host ("DRYRUN would run: {0} {1}" -f $CheckScriptPath, ($compatArgs -join " ")) -ForegroundColor Gray
      } else {
        Write-Host ("DRYRUN would run: {0}" -f $CheckScriptPath) -ForegroundColor Gray
      }
      if ($effectiveIsolateOnNoChanges) {
        $isolateParams = Get-IsolationParam
        $isolateExtraArgs = Get-IsolationExtraArg
        $prettyParams = Format-IsolationParamsForDisplay -Params $isolateParams
        if ($isolateExtraArgs.Count -gt 0) {
          Write-Host ("DRYRUN would run (on no changes): {0} {1} {2}" -f $IsolateScriptPath, ($prettyParams -join " "), ($isolateExtraArgs -join " ")) -ForegroundColor Gray
        } else {
          Write-Host ("DRYRUN would run (on no changes): {0} {1}" -f $IsolateScriptPath, ($prettyParams -join " ")) -ForegroundColor Gray
        }
      }
    }

    if ($null -ne $outcome.Window) {
      $lastCrashDialogHandleId = [long]$outcome.Window.Handle.ToInt64()
      if ($CrashCloseClickOffsetX -ge 0 -and $CrashCloseClickOffsetY -ge 0) {
        Start-Sleep -Seconds $CrashCloseDelaySeconds
        Invoke-ClickRelativeToWindow -Handle $outcome.Window.Handle -OffsetX $CrashCloseClickOffsetX -OffsetY $CrashCloseClickOffsetY -IsDryRun ([bool]$DryRun)
      }
    }

    # * Fabric can show its own incompatibility dialog alongside the generic crash dialog.
    # * Close it to keep automation continuous and allow launcher to return.
    $fabricWindow = Select-WindowByTitlePattern -Patterns $FabricWindowTitlePatterns
    Close-FabricDialogWindow -Window $fabricWindow -IsDryRun ([bool]$DryRun)

    # * Wait before retrying after a crash.
    Write-Host "Waiting 5 seconds before retry..." -ForegroundColor Cyan
    Start-Sleep -Seconds 5
    continue
  }

  if ($outcome.Type -eq "FabricDialog") {
    Write-Host "Outcome: Fabric Loader dialog detected." -ForegroundColor Yellow
    Close-FabricDialogWindow -Window $outcome.Window -IsDryRun ([bool]$DryRun)
  } elseif ($outcome.Type -eq "UnknownWindow") {
    Write-Host "Outcome: unknown blocking window detected." -ForegroundColor Yellow
    Write-Host "Обнаружено неизвестное окно. Пожалуйста, закройте его и продолжите." -ForegroundColor Yellow
    $unknownTitle = ""
    $unknownHandleId = 0
    if ($null -ne $outcome.Window) {
      $unknownTitle = [string]$outcome.Window.Title
      $unknownHandleId = [long]$outcome.Window.Handle.ToInt64()
    }
    if ($unknownHandleId -ne 0) {
      Request-UserToCloseUnknownWindow -HandleId $unknownHandleId -WindowTitle $unknownTitle
    }
    Write-Host "Неизвестное окно закрыто. Продолжаю попытки без отката модов." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    continue
  } else {
    Write-Host ("Outcome: no crash/fabric dialog detected within {0} seconds." -f $OutcomeTimeoutSeconds) -ForegroundColor Green
  }
  if (-not $DryRun) {
    $closedAfterNonCrashOutcome = Stop-SessionGameProcess -GameProcessNames $GameProcessNames -StartedAfter $sessionStartTime
    if ($closedAfterNonCrashOutcome -gt 0) {
      Write-Host ("Closed {0} running game process(es) before prompt." -f $closedAfterNonCrashOutcome) -ForegroundColor Gray
    }
  }
  $hasSessionIsolants = $sessionIsolationCulpritByJar.Count -gt 0
  if ($hasSessionIsolants) {
    $isolatedNames = @($sessionIsolationCulpritByJar.Values | ForEach-Object { $_.JarName } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    if ($isolatedNames -and $isolatedNames.Count -gt 0) {
      Write-Host ""
      Write-Host ("Isolation note: mods isolated (moved to Legacy) in this session: {0}" -f ($isolatedNames -join ", ")) -ForegroundColor Yellow
      Write-Host "To retry the launch WITH these mods, they must be restored from Legacy first." -ForegroundColor Yellow
      Write-Host ""
    }
  }
  $prompt = $null
  if ($outcome.Type -eq "FabricDialog") {
    $prompt = $(if ($hasSessionIsolants) { "Обнаружено окно Fabric Loader (несовместимость/зависимости). Выберите действие для изолированных модов:" } else { "Обнаружено окно Fabric Loader (несовместимость/зависимости). Продолжить попытки? (y/n)" })
  } else {
    $prompt = $(if ($hasSessionIsolants) { "Краш не обнаружен. Выберите действие для изолированных модов:" } else { "Краш не обнаружен. Продолжить попытки? (y/n)" })
  }

  if ($hasSessionIsolants) {
    Write-Host $prompt -ForegroundColor Yellow
    Write-Host "  c = продолжить с текущими изолятами (неполный набор модов)." -ForegroundColor Gray
    Write-Host "  r = вернуть изоляты и продолжить с полного набора." -ForegroundColor Gray
    Write-Host "  n = вернуть изоляты и завершить." -ForegroundColor Gray

    $choice = ""
    while ([string]::IsNullOrWhiteSpace($choice)) {
      $answerRaw = [string](Read-Host "Выбор [c/r/n]")
      $answer = $answerRaw.Trim().ToLowerInvariant()
      if ($answer -match "^(c|continue|к)$") {
        $choice = "continue-as-is"
        break
      }
      if ($answer -match "^(r|restore|y|yes|д|да|в)$") {
        $choice = "restore-and-continue"
        break
      }
      if ($answer -match "^(n|no|н|нет)$") {
        $choice = "restore-and-exit"
        break
      }
      Write-Host "Неверный ввод. Введите c, r или n." -ForegroundColor Yellow
    }

    if ($choice -eq "continue-as-is") {
      Write-Host "Продолжаю попытки без деизолирования модов." -ForegroundColor Cyan
      Start-Sleep -Seconds 1
      continue
    }

    $restoreLabel = if ($choice -eq "restore-and-exit") { "before exit" } else { "before continuing" }
    Write-Host ("Restoring isolated mods {0}..." -f $restoreLabel) -ForegroundColor Cyan
    $ok = Restore-IsolationCulpritMod -CulpritMoves @($sessionIsolationCulpritByJar.Values)
    if (-not $ok) {
      Write-Host "Warning: some isolated mods could not be restored automatically. Please review Legacy folders." -ForegroundColor Yellow
      exit 1
    }
    $sessionIsolationCulpritByJar = @{}

    if ($choice -eq "restore-and-exit") {
      Write-Host "Если скрипт не устранил проблему или сломался об некоторые моды и их зависимости - на период работы скрипта изолируйте эти токсичные моды вручную." -ForegroundColor Yellow
      Write-Host "Stopping by user choice." -ForegroundColor Yellow
      exit 0
    }

    continue
  }

  $answer = Read-Host $prompt
  if ($answer -notmatch "^(y|yes|д|да)$") {
    if ($hasSessionIsolants) {
      Write-Host "Restoring isolated mods before exit..." -ForegroundColor Cyan
      $ok = Restore-IsolationCulpritMod -CulpritMoves @($sessionIsolationCulpritByJar.Values)
      if (-not $ok) {
        Write-Host "Warning: some isolated mods could not be restored automatically. Please review Legacy folders." -ForegroundColor Yellow
        exit 1
      }
      $sessionIsolationCulpritByJar = @{}
    }
    Write-Host "Если скрипт не устранил проблему или сломался об некоторые моды и их зависимости - на период работы скрипта изолируйте эти токсичные моды вручную." -ForegroundColor Yellow
    Write-Host "Stopping by user choice." -ForegroundColor Yellow
    exit 0
  }

  if ($hasSessionIsolants) {
    Write-Host "Restoring isolated mods before continuing..." -ForegroundColor Cyan
    $ok = Restore-IsolationCulpritMod -CulpritMoves @($sessionIsolationCulpritByJar.Values)
    if (-not $ok) {
      Write-Host "Warning: some isolated mods could not be restored automatically. Please review Legacy folders." -ForegroundColor Yellow
      exit 1
    }
    $sessionIsolationCulpritByJar = @{}
  }
}
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
      } catch {
        Write-Host ("Warning: auto-restore failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
      }
    }
    else {
      Write-Host ("Warning: restore script not found: {0}" -f $restoreScriptPath) -ForegroundColor Yellow
    }
  }

  try {
    if (-not $DryRun) {
      [void](Stop-SessionGameProcess -GameProcessNames $GameProcessNames -StartedAfter $sessionStartTime)
    }
    if ($sessionIsolationCulpritHistoryByJar.Count -eq 0 -and (Test-Path -LiteralPath $transcriptLogPath)) {
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

    $latestCompatReportPath = Get-LatestCompatReportPath -ReportDir $PSScriptRoot
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
}
