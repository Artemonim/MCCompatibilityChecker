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

try {
  if ($enableTranscript) {
    if (Test-Path -LiteralPath $transcriptLogPath) {
      Remove-Item -LiteralPath $transcriptLogPath -Force -ErrorAction Stop
    }
    Start-Transcript -Path $transcriptLogPath -Force | Out-Null
    $transcriptStarted = $true
  }

  $effectiveAutoLaunch = ([bool]$UseAutoLaunch) -and (-not [bool]$DisableAutoLaunch)

if ($Help) {
  Get-Help -Full -Name $PSCommandPath
  return
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

function New-CompatibilityArgs {
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
  return $compatArgs
}

function Get-IsolationExtraArgs {
  $isolateExtraArgs = @()
  if ($IsolateScriptArguments) {
    foreach ($arg in $IsolateScriptArguments) {
      if (-not [string]::IsNullOrWhiteSpace($arg)) {
        $isolateExtraArgs += @($arg)
      }
    }
  }
  return $isolateExtraArgs
}

function New-IsolationParams {
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
  return $isolateParams
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
  return $prettyParams
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

  while ((Get-Date) -lt $deadline) {
    $crashWindow = Select-WindowByTitlePatterns -Patterns $CrashPatterns -ExcludeHandleIds $IgnoreCrashHandleIds
    if ($null -ne $crashWindow) {
      return [pscustomobject]@{ Type = "CrashDialog"; Window = $crashWindow }
    }

    $fabricWindow = Select-WindowByTitlePatterns -Patterns $FabricPatterns
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
          return [pscustomobject]@{ Type = "Timeout"; Window = $null }
        }
      }
    }

    Start-Sleep -Seconds $PollSeconds
  }

  return [pscustomobject]@{ Type = "Timeout"; Window = $null }
}

function Restore-IsolationCulpritMods {
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
      [scriptblock]$Action
    )
    for ($i = 0; $i -le $Retries; $i++) {
      try {
        & $Action
        return $true
      } catch [System.IO.IOException] {
        if ($i -ge $Retries) { throw }
        Start-Sleep -Milliseconds $DelayMs
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
            Invoke-WithRetry -Action { Move-Item -LiteralPath $storageLegacyPath -Destination $storageTarget -Force -ErrorAction Stop } | Out-Null
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
          Invoke-WithRetry -Action { Move-Item -LiteralPath $gameLegacyPath -Destination $gameTarget -Force -ErrorAction Stop } | Out-Null
          Write-Host ("Restored game mod: {0}" -f $gameTarget) -ForegroundColor Green
          continue
        }

        # * Fallback: copy from storage root (preferred) or from storage legacy.
        if ($storageTarget -and (Test-Path -LiteralPath $storageTarget)) {
          Invoke-WithRetry -Action { Copy-Item -LiteralPath $storageTarget -Destination $gameTarget -Force -ErrorAction Stop } | Out-Null
          Write-Host ("Restored game mod (copied from storage): {0}" -f $gameTarget) -ForegroundColor Green
          continue
        }
        if (-not [string]::IsNullOrWhiteSpace($storageLegacyPath) -and (Test-Path -LiteralPath $storageLegacyPath)) {
          Invoke-WithRetry -Action { Copy-Item -LiteralPath $storageLegacyPath -Destination $gameTarget -Force -ErrorAction Stop } | Out-Null
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

  if ($outcome.Type -eq "CrashDialog") {
    Write-Host "Outcome: crash dialog detected. Running compatibility cleanup." -ForegroundColor Yellow

    if (-not $DryRun) {
      $compatArgs = New-CompatibilityArgs
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
            Write-Host "Compatibility cleanup made no changes. Running isolation." -ForegroundColor Cyan
            $isolateParams = New-IsolationParams -IncludeEmitResultObject $true -IncludeFastForward $true -IncludeKeepCulpritInGameLegacy $true
            $isolateExtraArgs = Get-IsolationExtraArgs

            $isolationResult = & $IsolateScriptPath @isolateParams @isolateExtraArgs
            $isolateExitCode = $LASTEXITCODE
            if ($isolateExitCode -ne 0) {
              Write-Host ("Isolation failed with exit code {0}. Stopping." -f $isolateExitCode) -ForegroundColor Red
              exit $isolateExitCode
            }

            $isolationResultObj = $isolationResult
            if ($isolationResultObj -is [System.Array]) {
              $isolationResultObj = $isolationResultObj | Select-Object -Last 1
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
                }
              }
            }

            Write-Host "Isolation completed. Returning to main loop." -ForegroundColor Cyan
            Start-Sleep -Seconds 2
            continue
          }
          Write-Host "Compatibility cleanup made no changes. Stopping to avoid a loop." -ForegroundColor Yellow
          exit 3
        }
        Write-Host ("Compatibility cleanup failed with exit code {0}. Stopping." -f $compatExitCode) -ForegroundColor Red
        exit $compatExitCode
      }
    } else {
      $compatArgs = New-CompatibilityArgs
      if ($compatArgs.Count -gt 0) {
        Write-Host ("DRYRUN would run: {0} {1}" -f $CheckScriptPath, ($compatArgs -join " ")) -ForegroundColor Gray
      } else {
        Write-Host ("DRYRUN would run: {0}" -f $CheckScriptPath) -ForegroundColor Gray
      }
      if ($effectiveIsolateOnNoChanges) {
        $isolateParams = New-IsolationParams
        $isolateExtraArgs = Get-IsolationExtraArgs
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
    $fabricWindow = Select-WindowByTitlePatterns -Patterns $FabricWindowTitlePatterns
    Close-FabricDialogWindow -Window $fabricWindow -IsDryRun ([bool]$DryRun)

    # * Wait before retrying after a crash.
    Write-Host "Waiting 5 seconds before retry..." -ForegroundColor Cyan
    Start-Sleep -Seconds 5
    continue
  }

  if ($outcome.Type -eq "FabricDialog") {
    Write-Host "Outcome: Fabric Loader dialog detected." -ForegroundColor Yellow
    Close-FabricDialogWindow -Window $outcome.Window -IsDryRun ([bool]$DryRun)
  } else {
    Write-Host ("Outcome: timeout after {0} seconds." -f $OutcomeTimeoutSeconds) -ForegroundColor Green
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
    $prompt = $(if ($hasSessionIsolants) { "Обнаружено окно Fabric Loader (несовместимость/зависимости). Вернуть изолированные моды и продолжить попытки? (y/n)" } else { "Обнаружено окно Fabric Loader (несовместимость/зависимости). Продолжить попытки? (y/n)" })
  } else {
    $prompt = $(if ($hasSessionIsolants) { "Краш не обнаружен. Вернуть изолированные моды и продолжить попытки? (y/n)" } else { "Краш не обнаружен. Продолжить попытки? (y/n)" })
  }
  $answer = Read-Host $prompt
  if ($answer -notmatch "^(y|yes|д|да)$") {
    if ($hasSessionIsolants) {
      Write-Host "Restoring isolated mods before exit..." -ForegroundColor Cyan
      $ok = Restore-IsolationCulpritMods -CulpritMoves @($sessionIsolationCulpritByJar.Values)
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
    $ok = Restore-IsolationCulpritMods -CulpritMoves @($sessionIsolationCulpritByJar.Values)
    if (-not $ok) {
      Write-Host "Warning: some isolated mods could not be restored automatically. Please review Legacy folders." -ForegroundColor Yellow
      exit 1
    }
    $sessionIsolationCulpritByJar = @{}
  }
}
} finally {
  if ($transcriptStarted) {
    Stop-Transcript | Out-Null
  }
}
