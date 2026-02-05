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
  [string]$GameModsDir = "C:\Users\Artem\AppData\Roaming\.tlauncher\legacy\Minecraft\game\mods",

  # * Folder name inside GameModsDir used to store quarantined mods.
  [Parameter(Mandatory = $false)]
  [string]$GameLegacyFolderName = "legacy",

  # * Optional storage mods folder. If empty, storage operations are skipped.
  [Parameter(Mandatory = $false)]
  [string]$StorageModsDir = "D:\Установщики игр\MineCraft 1.21\Mods",

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

  # * Array of jar file names to skip.
  [Parameter(Mandatory = $false)]
  [string[]]$ExcludeJarNames = @(),

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

$effectiveIsolationStrategy = if ($UseLinearIsolation) { "Linear" } else { "Exponential" }
if ($BinaryLinearThreshold -lt 1) { $BinaryLinearThreshold = 1 }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName System.Windows.Forms

if (-not ("MCCompatWin32" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MCCompatWin32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

  [DllImport("user32.dll")]
  public static extern int GetWindowTextLength(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }

  [DllImport("user32.dll")]
  public static extern bool GetCursorPos(out POINT pt);

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT {
    public int X;
    public int Y;
  }

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int X, int Y);

  [DllImport("user32.dll")]
  public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

  [DllImport("user32.dll")]
  public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@
}

function New-DirectoryIfMissing {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [string]$DirPath
  )
  if (-not (Test-Path -LiteralPath $DirPath)) {
    if ($PSCmdlet.ShouldProcess($DirPath, "Create directory")) {
      New-Item -ItemType Directory -Path $DirPath -Force | Out-Null
    }
  }
}

function Test-TitleMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Title,
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  $escaped = [regex]::Escape($Pattern)
  return [regex]::IsMatch($Title, $escaped, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-RecentProcessesByName {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Names,
    [Parameter(Mandatory = $true)]
    [datetime]$StartedAfter
  )

  $set = @{}
  foreach ($name in $Names) {
    if (-not [string]::IsNullOrWhiteSpace($name)) {
      $set[$name.ToLowerInvariant()] = $true
    }
  }
  if ($set.Count -eq 0) { return @() }

  $recent = New-Object System.Collections.Generic.List[object]
  $all = Get-Process -ErrorAction SilentlyContinue
  foreach ($p in $all) {
    if (-not $p -or [string]::IsNullOrWhiteSpace($p.Name)) { continue }
    $key = $p.Name.ToLowerInvariant()
    if (-not $set.ContainsKey($key)) { continue }
    try {
      $startTime = $p.StartTime
    } catch {
      continue
    }
    if ($startTime -ge $StartedAfter) {
      $recent.Add($p)
    }
  }
  # ! PowerShell 7.5 can throw "Argument types do not match" when expanding a generic List via @(...).
  # ! Return a native array to avoid the enumerable binder bug.
  # ! Use unary comma to prevent single-element array unwrapping (which would lose .Count property).
  return ,$recent.ToArray()
}

function Test-ProcessLooksLikeMinecraftGame {
  <#
  .SYNOPSIS
  Checks whether a recently started process likely belongs to Minecraft.

  .DESCRIPTION
  The launcher/game commonly runs under java/javaw, which is too generic for "game started" detection.
  This helper uses Win32_Process.CommandLine to confirm the java/javaw process is a Minecraft client.
  #>
  param(
    [Parameter(Mandatory = $true)]
    $Process
  )

  if ($null -eq $Process) { return $false }
  $name = [string]$Process.Name
  if ([string]::IsNullOrWhiteSpace($name)) { return $false }
  $nameLower = $name.ToLowerInvariant()

  # * Non-java game processes can be treated as a positive signal.
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

  # * net.minecraft.* is a strong signal that this java/javaw belongs to the Minecraft client.
  return ($cmd -match "net\.minecraft")
}

function Wait-ForGameProcessesToExit {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Names,
    [Parameter(Mandatory = $true)]
    [datetime]$StartedAfter,
    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds,
    [Parameter(Mandatory = $true)]
    [int]$PollSeconds
  )

  if ($TimeoutSeconds -le 0) { return $true }
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $recent = Get-RecentProcessesByName -Names $Names -StartedAfter $StartedAfter
    if (-not $recent -or $recent.Count -eq 0) {
      return $true
    }
    Start-Sleep -Seconds $PollSeconds
  }
  return $false
}

function Get-WindowList {
  $windows = New-Object System.Collections.Generic.List[object]

  $callback = [MCCompatWin32+EnumWindowsProc]{
    param([IntPtr]$hWnd, [IntPtr]$lParam)

    $null = $lParam
    if (-not [MCCompatWin32]::IsWindowVisible($hWnd)) { return $true }
    $length = [MCCompatWin32]::GetWindowTextLength($hWnd)
    if ($length -le 0) { return $true }

    $builder = New-Object System.Text.StringBuilder ($length + 1)
    [void][MCCompatWin32]::GetWindowText($hWnd, $builder, $builder.Capacity)
    $title = $builder.ToString()
    if ([string]::IsNullOrWhiteSpace($title)) { return $true }

    $processId = 0
    [void][MCCompatWin32]::GetWindowThreadProcessId($hWnd, [ref]$processId)
    $windows.Add([pscustomobject]@{
        Handle = $hWnd
        Title = $title
        ProcessId = $processId
      })
    return $true
  }

  [void][MCCompatWin32]::EnumWindows($callback, [IntPtr]::Zero)
  return $windows
}

function Select-WindowByTitlePatterns {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Patterns,
    [Parameter(Mandatory = $false)]
    [long[]]$ExcludeHandleIds = @()
  )

  $excludeSet = @{}
  foreach ($id in $ExcludeHandleIds) {
    if ($null -eq $id -or $id -eq 0) { continue }
    $excludeSet[[long]$id] = $true
  }

  $windows = Get-WindowList
  foreach ($window in $windows) {
    if ($excludeSet.Count -gt 0) {
      $handleId = [long]$window.Handle.ToInt64()
      if ($excludeSet.ContainsKey($handleId)) { continue }
    }
    foreach ($pattern in $Patterns) {
      if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
      if (Test-TitleMatch -Title $window.Title -Pattern $pattern) {
        return $window
      }
    }
  }
  return $null
}

function Wait-ForLauncherWindow {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TitlePattern,
    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $window = Select-WindowByTitlePatterns -Patterns @($TitlePattern)
    if ($null -ne $window) { return $window }
    Start-Sleep -Seconds 1
  }
  return $null
}

function Start-LauncherIfNeeded {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [string]$TitlePattern,
    [Parameter(Mandatory = $false)]
    [string]$ExePath,
    [Parameter(Mandatory = $false)]
    [string[]]$ExeArguments,
    [Parameter(Mandatory = $false)]
    [bool]$AppendAutoLaunch,
    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds
  )

  $existing = Select-WindowByTitlePatterns -Patterns @($TitlePattern)
  if ($null -ne $existing) { return $existing }

  if ([string]::IsNullOrWhiteSpace($ExePath)) {
    $waited = Wait-ForLauncherWindow -TitlePattern $TitlePattern -TimeoutSeconds $TimeoutSeconds
    if ($null -eq $waited) {
      Write-Host ("Launcher window not found after {0}s." -f $TimeoutSeconds) -ForegroundColor Yellow
    }
    return $waited
  }
  if (-not (Test-Path -LiteralPath $ExePath)) {
    throw ("LauncherExePath not found: {0}" -f $ExePath)
  }

  $startArgs = New-Object System.Collections.Generic.List[string]
  foreach ($arg in $ExeArguments) {
    if (-not [string]::IsNullOrWhiteSpace($arg)) {
      $startArgs.Add($arg)
    }
  }
  if ($AppendAutoLaunch) {
    $hasLaunch = $false
    foreach ($arg in $startArgs) {
      if ($arg -ieq "--launch") {
        $hasLaunch = $true
        break
      }
    }
    if (-not $hasLaunch) {
      $startArgs.Add("--launch")
    }
  }

  Write-Host ("Starting launcher: {0}" -f $ExePath) -ForegroundColor Cyan
  if (-not $PSCmdlet.ShouldProcess($ExePath, "Start-Process")) {
    return $null
  }
  if ($startArgs.Count -gt 0) {
    Start-Process -FilePath $ExePath -ArgumentList $startArgs | Out-Null
  } else {
    Start-Process -FilePath $ExePath | Out-Null
  }

  $started = Wait-ForLauncherWindow -TitlePattern $TitlePattern -TimeoutSeconds $TimeoutSeconds
  if ($null -eq $started) {
    throw ("Launcher window not found after {0}s." -f $TimeoutSeconds)
  }
  return $started
}

function Get-CursorOffsetRelativeToWindow {
  param(
    [Parameter(Mandatory = $true)]
    [IntPtr]$Handle
  )

  $rect = New-Object MCCompatWin32+RECT
  if (-not [MCCompatWin32]::GetWindowRect($Handle, [ref]$rect)) {
    throw "Failed to read window rectangle."
  }
  $point = New-Object MCCompatWin32+POINT
  if (-not [MCCompatWin32]::GetCursorPos([ref]$point)) {
    throw "Failed to read cursor position."
  }
  return [pscustomobject]@{
    OffsetX = $point.X - $rect.Left
    OffsetY = $point.Y - $rect.Top
  }
}

function Invoke-ClickRelativeToWindow {
  param(
    [Parameter(Mandatory = $true)]
    [IntPtr]$Handle,
    [Parameter(Mandatory = $true)]
    [int]$OffsetX,
    [Parameter(Mandatory = $true)]
    [int]$OffsetY
  )

  $rect = New-Object MCCompatWin32+RECT
  if (-not [MCCompatWin32]::GetWindowRect($Handle, [ref]$rect)) {
    throw "Failed to read window rectangle."
  }
  $targetX = $rect.Left + $OffsetX
  $targetY = $rect.Top + $OffsetY
  [void][MCCompatWin32]::SetCursorPos($targetX, $targetY)
  [MCCompatWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  [MCCompatWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function Invoke-LauncherPlay {
  param(
    [Parameter(Mandatory = $true)]
    [IntPtr]$LauncherHandle,
    [Parameter(Mandatory = $true)]
    [string[]]$ButtonNames,
    [Parameter(Mandatory = $true)]
    [int]$ClickOffsetX,
    [Parameter(Mandatory = $true)]
    [int]$ClickOffsetY,
    [Parameter(Mandatory = $true)]
    [bool]$EnableEnterFallback,
    [Parameter(Mandatory = $true)]
    [bool]$AllowBroadSearch,
    [Parameter(Mandatory = $false)]
    [int]$PreClickDelayMs = 0
  )

  [void][MCCompatWin32]::SetForegroundWindow($LauncherHandle)
  Start-Sleep -Milliseconds 150
  if ($PreClickDelayMs -gt 0) {
    Start-Sleep -Milliseconds $PreClickDelayMs
  }

  # * Prefer offset click to avoid UI Automation hangs.
  if ($ClickOffsetX -ge 0 -and $ClickOffsetY -ge 0) {
    Write-Host ("Clicking Play by offsets: X={0}, Y={1}" -f $ClickOffsetX, $ClickOffsetY) -ForegroundColor Cyan
    Invoke-ClickRelativeToWindow -Handle $LauncherHandle -OffsetX $ClickOffsetX -OffsetY $ClickOffsetY
    return
  }
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($LauncherHandle)
  if ($null -eq $root) {
    throw "Failed to access launcher automation element."
  }

  # * Strict search: Button control type + exact Name.
  foreach ($buttonName in $ButtonNames) {
    if ([string]::IsNullOrWhiteSpace($buttonName)) { continue }
    $condition = New-Object System.Windows.Automation.AndCondition(
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button
      )),
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $buttonName
      ))
    )

    $button = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ($null -ne $button) {
      $invokePattern = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern) -as [System.Windows.Automation.InvokePattern]
      if ($null -ne $invokePattern) {
        $invokePattern.Invoke()
        return
      }
    }
  }

  if ($EnableEnterFallback) {
    Write-Host "Play element not found via UI Automation. Using ENTER fallback." -ForegroundColor Cyan
    [void][MCCompatWin32]::SetForegroundWindow($LauncherHandle)
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    return
  }

  # * Optional broad fallback (can be slow on some launchers).
  if ($AllowBroadSearch) {
    Write-Host "Using broad UI Automation search fallback for Play element." -ForegroundColor Cyan
    $buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Button
    )
    $allButtons = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
    foreach ($element in $allButtons) {
      $name = $element.Current.Name
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      foreach ($buttonName in $ButtonNames) {
        if (Test-TitleMatch -Title $name -Pattern $buttonName) {
          $invokePattern = $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern) -as [System.Windows.Automation.InvokePattern]
          if ($null -ne $invokePattern) {
            $invokePattern.Invoke()
            return
          }
          $legacyPattern = $element.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern) -as [System.Windows.Automation.LegacyIAccessiblePattern]
          if ($null -ne $legacyPattern) {
            $legacyPattern.DoDefaultAction()
            return
          }
        }
      }
    }
  }

  throw ("Play element not found. Set -PlayClickOffsetX/Y or enable Enter fallback. Names tried: {0}" -f ($ButtonNames -join ", "))
}

function Invoke-WindowClose {
  param(
    [Parameter(Mandatory = $true)]
    [IntPtr]$Handle
  )

  $wmClose = 0x0010
  [void][MCCompatWin32]::SendMessage($Handle, $wmClose, [IntPtr]::Zero, [IntPtr]::Zero)
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
    [datetime]$LaunchStart,
    [Parameter(Mandatory = $false)]
    [string[]]$GameProcessNames = @(),
    [Parameter(Mandatory = $false)]
    [long]$LauncherHandleId = 0,
    [Parameter(Mandatory = $false)]
    [int]$LaunchStartTimeoutSeconds = 0,
    [Parameter(Mandatory = $false)]
    [bool]$RequireGameStartForTimeout = $false,
    [Parameter(Mandatory = $false)]
    [long[]]$IgnoreHandleIds = @()
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $launchStartDeadline = $null
  if ($LaunchStartTimeoutSeconds -gt 0) {
    $launchStartDeadline = $LaunchStart.AddSeconds($LaunchStartTimeoutSeconds)
  }

  $gameStarted = $false
  $launcherClosed = $false
  $logUpdated = $false
  $observedGamePids = @{}
  $gameObservedOnce = $false
  $gameExited = $false

  while ((Get-Date) -lt $deadline) {
    $fabricWindow = Select-WindowByTitlePatterns -Patterns $FabricPatterns
    if ($null -ne $fabricWindow) {
      return [pscustomobject]@{
        Type = "FabricDialog"
        Window = $fabricWindow
        GameStarted = $gameStarted
        LauncherClosed = $launcherClosed
        LaunchObserved = $true
      }
    }

    $crashWindow = Select-WindowByTitlePatterns -Patterns $CrashPatterns -ExcludeHandleIds $IgnoreHandleIds
    if ($null -ne $crashWindow) {
      return [pscustomobject]@{
        Type = "CrashDialog"
        Window = $crashWindow
        GameStarted = $gameStarted
        LauncherClosed = $launcherClosed
        LaunchObserved = $true
      }
    }

    if (-not $logUpdated) {
      # * Track whether the launcher wrote a new temp log since the click.
      $latestTlLog = Get-LatestTLauncherLogPathOrNull -PreferredPath ""
      if (-not [string]::IsNullOrWhiteSpace($latestTlLog)) {
        $tlItem = Get-Item -LiteralPath $latestTlLog -ErrorAction SilentlyContinue
        if ($null -ne $tlItem -and $tlItem.LastWriteTime -ge $LaunchStart) {
          $logUpdated = $true
        }
      }
    }

    if ($GameProcessNames -and $GameProcessNames.Count -gt 0) {
      $recent = Get-RecentProcessesByName -Names $GameProcessNames -StartedAfter $LaunchStart
      foreach ($p in $recent) {
        if (Test-ProcessLooksLikeMinecraftGame -Process $p) {
          $gameStarted = $true
          $gameObservedOnce = $true
          try {
            $observedGamePids[[int]$p.Id] = $true
          } catch {
            Write-Verbose ("Skipping invalid game process id: {0}" -f $p.Id)
          }
        }
      }
    }

    if ($gameObservedOnce) {
      $stillRunning = $false
      foreach ($processId in @($observedGamePids.Keys)) {
        $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $proc) {
          $observedGamePids.Remove($processId) | Out-Null
          $gameExited = $true
          continue
        }
        $stillRunning = $true
      }
      if ($gameExited -and (-not $stillRunning)) {
        return [pscustomobject]@{
          Type = "ProcessExit"
          Window = $null
          GameStarted = $gameStarted
          LauncherClosed = $launcherClosed
          LaunchObserved = $true
        }
      }
    }

    if (-not $launcherClosed -and $LauncherHandleId -ne 0) {
      if (-not (Test-WindowStillExists -HandleId $LauncherHandleId)) {
        $launcherClosed = $true
      }
    }

    # * Launch trigger can be inferred by either a game process start or the launcher disappearing.
    # * Success is gated by gameStarted (see RequireGameStartForTimeout below).
    $launchTriggered = $gameStarted -or $launcherClosed -or $logUpdated
    if (-not $launchTriggered -and $null -ne $launchStartDeadline -and (Get-Date) -ge $launchStartDeadline) {
      return [pscustomobject]@{
        Type = "NoLaunch"
        Window = $null
        GameStarted = $gameStarted
        LauncherClosed = $launcherClosed
        LaunchObserved = $launchTriggered
      }
    }

    Start-Sleep -Seconds $PollSeconds
  }

  $launchTriggered = $gameStarted -or $launcherClosed -or $logUpdated
  if ($RequireGameStartForTimeout -and (-not $gameStarted)) {
    return [pscustomobject]@{
      Type = "NoLaunch"
      Window = $null
      GameStarted = $gameStarted
      LauncherClosed = $launcherClosed
      LaunchObserved = $launchTriggered
    }
  }
  if ($RequireGameStartForTimeout -and $gameObservedOnce -and $observedGamePids.Count -eq 0) {
    return [pscustomobject]@{
      Type = "ProcessExit"
      Window = $null
      GameStarted = $gameStarted
      LauncherClosed = $launcherClosed
      LaunchObserved = $launchTriggered
    }
  }

  return [pscustomobject]@{
    Type = "Timeout"
    Window = $null
    GameStarted = $gameStarted
    LauncherClosed = $launcherClosed
    LaunchObserved = $launchTriggered
  }
}

function Close-OutcomeWindow {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Outcome,
    [Parameter(Mandatory = $true)]
    [int]$DelaySeconds,
    [Parameter(Mandatory = $true)]
    [int]$OffsetX,
    [Parameter(Mandatory = $true)]
    [int]$OffsetY
  )

  if ($null -eq $Outcome.Window) { return }
  Start-Sleep -Seconds $DelaySeconds
  if ($OffsetX -ge 0 -and $OffsetY -ge 0) {
    Invoke-ClickRelativeToWindow -Handle $Outcome.Window.Handle -OffsetX $OffsetX -OffsetY $OffsetY
  } else {
    Invoke-WindowClose -Handle $Outcome.Window.Handle
  }
  # * Give window time to close after WM_CLOSE.
  Start-Sleep -Milliseconds 500

  # * Fallback: some dialogs ignore WM_CLOSE; try Alt+F4.
  $handleId = [long]$Outcome.Window.Handle.ToInt64()
  if (Test-WindowStillExists -HandleId $handleId) {
    [void][MCCompatWin32]::SetForegroundWindow($Outcome.Window.Handle)
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.SendKeys]::SendWait("%{F4}")
    Start-Sleep -Milliseconds 500
  }

  if (Test-WindowStillExists -HandleId $handleId) {
    Request-UserToCloseBlockingWindow -HandleId $handleId -WindowTitle $Outcome.Window.Title
  }
}

function Test-WindowStillExists {
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

function Request-UserToCloseBlockingWindow {
  param(
    [Parameter(Mandatory = $true)]
    [long]$HandleId,
    [Parameter(Mandatory = $false)]
    [string]$WindowTitle = ""
  )

  if ($HandleId -eq 0) { return }

  $label = if ([string]::IsNullOrWhiteSpace($WindowTitle)) { "неизвестное мешающее окно" } else { $WindowTitle }
  $message = "Не удалось закрыть мешающее окно автоматически. Закройте его вручную и нажмите OK для продолжения.`nОкно: {0}" -f $label

  while (Test-WindowStillExists -HandleId $HandleId) {
    [void][System.Windows.Forms.MessageBox]::Show(
      $message,
      "Требуется действие пользователя",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    Start-Sleep -Milliseconds 300
  }
}

function Wait-ForLauncherWindowInteractive {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TitlePattern,
    [Parameter(Mandatory = $true)]
    [string[]]$CrashPatterns,
    [Parameter(Mandatory = $true)]
    [string[]]$FabricPatterns,
    [Parameter(Mandatory = $true)]
    [int]$PollSeconds
  )

  $promptMessage = "Не удалось увидеть окно лаунчера. Закройте неизвестное мешающее окно (включая игру, если она запущена) и нажмите OK для продолжения."
  while ($true) {
    $fabricWindow = Select-WindowByTitlePatterns -Patterns $FabricPatterns
    if ($null -ne $fabricWindow) {
      Write-Host ("Blocking Fabric dialog detected: {0}" -f $fabricWindow.Title) -ForegroundColor Yellow
      Close-OutcomeWindow -Outcome ([pscustomobject]@{ Type = "FabricDialog"; Window = $fabricWindow }) `
        -DelaySeconds 0 `
        -OffsetX -1 `
        -OffsetY -1
      Start-Sleep -Seconds $PollSeconds
      continue
    }

    $crashWindow = Select-WindowByTitlePatterns -Patterns $CrashPatterns
    if ($null -ne $crashWindow) {
      Write-Host ("Blocking crash dialog detected: {0}" -f $crashWindow.Title) -ForegroundColor Yellow
      Close-OutcomeWindow -Outcome ([pscustomobject]@{ Type = "CrashDialog"; Window = $crashWindow }) `
        -DelaySeconds 0 `
        -OffsetX -1 `
        -OffsetY -1
      Start-Sleep -Seconds $PollSeconds
      continue
    }

    $launcherWindow = Select-WindowByTitlePatterns -Patterns @($TitlePattern)
    if ($null -ne $launcherWindow) { return $launcherWindow }

    [void][System.Windows.Forms.MessageBox]::Show(
      $promptMessage,
      "Требуется действие пользователя",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    Start-Sleep -Seconds $PollSeconds
  }
}

function Invoke-LaunchAttempt {
  param(
    [Parameter(Mandatory = $true)]
    [string]$LauncherTitlePattern,
    [Parameter(Mandatory = $false)]
    [string]$LauncherPath,
    [Parameter(Mandatory = $false)]
    [string[]]$LauncherArgs,
    [Parameter(Mandatory = $false)]
    [bool]$AppendAutoLaunch,
    [Parameter(Mandatory = $true)]
    [int]$LauncherTimeoutSeconds,
    [Parameter(Mandatory = $true)]
    [string[]]$ButtonNames,
    [Parameter(Mandatory = $true)]
    [int]$ClickOffsetX,
    [Parameter(Mandatory = $true)]
    [int]$ClickOffsetY,
    [Parameter(Mandatory = $true)]
    [bool]$EnableEnterFallback,
    [Parameter(Mandatory = $true)]
    [bool]$AllowBroadSearch,
    [Parameter(Mandatory = $true)]
    [string[]]$CrashPatterns,
    [Parameter(Mandatory = $true)]
    [string[]]$FabricPatterns,
    [Parameter(Mandatory = $true)]
    [int]$OutcomeTimeoutSeconds,
    [Parameter(Mandatory = $true)]
    [int]$PollSeconds,
    [Parameter(Mandatory = $false)]
    [long[]]$IgnoreHandleIds = @()
  )

  # * Close any leftover dialogs that can block launcher interaction.
  $strayCrash = Select-WindowByTitlePatterns -Patterns $CrashPatterns
  if ($null -ne $strayCrash) {
    Write-Host ("Closing stray crash dialog before launching: {0}" -f $strayCrash.Title) -ForegroundColor Gray
    Close-OutcomeWindow -Outcome ([pscustomobject]@{ Type = "CrashDialog"; Window = $strayCrash }) `
      -DelaySeconds 0 `
      -OffsetX -1 `
      -OffsetY -1
  }
  $strayFabric = Select-WindowByTitlePatterns -Patterns $FabricPatterns
  if ($null -ne $strayFabric) {
    Write-Host ("Closing stray Fabric Loader dialog before launching: {0}" -f $strayFabric.Title) -ForegroundColor Gray
    Close-OutcomeWindow -Outcome ([pscustomobject]@{ Type = "FabricDialog"; Window = $strayFabric }) `
      -DelaySeconds 0 `
      -OffsetX -1 `
      -OffsetY -1
  }

  $launcherWindow = Start-LauncherIfNeeded -TitlePattern $LauncherTitlePattern `
    -ExePath $LauncherPath `
    -ExeArguments $LauncherArgs `
    -AppendAutoLaunch $AppendAutoLaunch `
    -TimeoutSeconds $LauncherTimeoutSeconds
  if ($null -eq $launcherWindow) {
    throw "Launcher window not found."
  }

  $launcherHandleId = [long]$launcherWindow.Handle.ToInt64()

  $maxPlayAttempts = $PlayClickMaxAttempts
  if ($maxPlayAttempts -lt 1) { $maxPlayAttempts = 1 }
  if ($LaunchStartTimeoutSeconds -gt $OutcomeTimeoutSeconds) {
    $LaunchStartTimeoutSeconds = $OutcomeTimeoutSeconds
  }

  for ($playAttempt = 1; $playAttempt -le $maxPlayAttempts; $playAttempt++) {
    if ($playAttempt -gt 1) {
      Write-Host ("Warning: no game launch detected. Retrying Play click ({0}/{1})..." -f $playAttempt, $maxPlayAttempts) -ForegroundColor Yellow
    }

    $launchStart = Get-Date
    Invoke-LauncherPlay -LauncherHandle $launcherWindow.Handle `
      -ButtonNames $ButtonNames `
      -ClickOffsetX $ClickOffsetX `
      -ClickOffsetY $ClickOffsetY `
      -EnableEnterFallback $EnableEnterFallback `
      -AllowBroadSearch $AllowBroadSearch `
      -PreClickDelayMs $PlayClickDelayMs

    $outcome = Wait-ForOutcome -CrashPatterns $CrashPatterns `
      -FabricPatterns $FabricPatterns `
      -TimeoutSeconds $OutcomeTimeoutSeconds `
      -PollSeconds $PollSeconds `
      -LaunchStart $launchStart `
      -GameProcessNames $GameProcessNames `
      -LauncherHandleId $launcherHandleId `
      -LaunchStartTimeoutSeconds $LaunchStartTimeoutSeconds `
      -RequireGameStartForTimeout ([bool]$RequireGameStartForTimeout) `
      -IgnoreHandleIds $IgnoreHandleIds

    if ($outcome.Type -ne "NoLaunch") {
      return $outcome
    }
  }

  throw ("No game launch detected after {0} Play click attempt(s). Consider increasing -PlayClickDelayMs or -LaunchStartTimeoutSeconds." -f $maxPlayAttempts)
}

function Get-LatestTLauncherLogPathOrNull {
  param(
    [Parameter(Mandatory = $false)]
    [string]$PreferredPath
  )

  if (-not [string]::IsNullOrWhiteSpace($PreferredPath) -and (Test-Path -LiteralPath $PreferredPath)) {
    return $PreferredPath
  }

  $tempDir = [System.IO.Path]::GetTempPath()
  $candidates = Get-ChildItem -LiteralPath $tempDir -Filter "tl-logger*.txt" -File -ErrorAction SilentlyContinue |
    Sort-Object -Property LastWriteTime -Descending
  if (-not $candidates -or $candidates.Count -eq 0) {
    return $null
  }
  return $candidates[0].FullName
}

function Get-GameRootFromModsDir {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModsDir
  )

  if ([string]::IsNullOrWhiteSpace($ModsDir)) { return $null }
  $parent = Split-Path -Path $ModsDir -Parent
  if ([string]::IsNullOrWhiteSpace($parent)) { return $null }
  if (-not (Test-Path -LiteralPath $parent)) { return $null }
  return $parent
}

function Get-AdditionalGameLogPaths {
  param(
    [Parameter(Mandatory = $true)]
    [string]$GameModsDir
  )

  $paths = New-Object System.Collections.Generic.List[string]
  $gameRoot = Get-GameRootFromModsDir -ModsDir $GameModsDir
  if (-not $gameRoot) { return $paths }

  $logsDir = Join-Path -Path $gameRoot -ChildPath "logs"
  foreach ($name in @("latest.log", "debug.log")) {
    $candidate = Join-Path -Path $logsDir -ChildPath $name
    if (Test-Path -LiteralPath $candidate) { $paths.Add($candidate) }
  }

  $crashDir = Join-Path -Path $gameRoot -ChildPath "crash-reports"
  if (Test-Path -LiteralPath $crashDir) {
    $latestCrash = Get-ChildItem -LiteralPath $crashDir -Filter "*.txt" -File -ErrorAction SilentlyContinue |
      Sort-Object -Property LastWriteTime -Descending |
      Select-Object -First 1
    if ($latestCrash) { $paths.Add($latestCrash.FullName) }
  }

  return $paths
}

function Select-RecentLogPaths {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Paths,
    [Parameter(Mandatory = $true)]
    [int]$MaxAgeMinutes
  )

  if (-not $Paths -or $Paths.Count -eq 0) { return @() }
  if ($MaxAgeMinutes -le 0) { return $Paths }

  $cutoff = (Get-Date).AddMinutes(-$MaxAgeMinutes)
  $recent = New-Object System.Collections.Generic.List[string]
  foreach ($path in $Paths) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($null -ne $item -and $item.LastWriteTime -ge $cutoff) {
      $recent.Add($path)
    }
  }
  return $recent
}

function Resolve-LogPaths {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PrimaryPath,
    [Parameter(Mandatory = $false)]
    [string[]]$AdditionalPaths = @()
  )

  $resolved = New-Object System.Collections.Generic.List[string]
  $seen = @{}

  if (-not [string]::IsNullOrWhiteSpace($PrimaryPath)) {
    $resolved.Add($PrimaryPath)
    $seen[$PrimaryPath.ToLowerInvariant()] = $true
  }

  foreach ($path in $AdditionalPaths) {
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    $key = $path.ToLowerInvariant()
    if (-not $seen.ContainsKey($key)) {
      $resolved.Add($path)
      $seen[$key] = $true
    }
  }

  return $resolved
}

function Read-AllLinesUtf8BestEffort {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )
  try {
    return [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
  } catch {
    # ! Some logs can be ANSI/Windows-1251 depending on tooling; fall back to default encoding.
    return Get-Content -LiteralPath $Path -ErrorAction Stop
  }
}

function Get-LineCountSafe {
  param(
    [Parameter(Mandatory = $false)]
    $Lines
  )

  if ($null -eq $Lines) { return 0 }
  if ($Lines -is [string]) {
    if ([string]::IsNullOrWhiteSpace($Lines)) { return 0 }
    return 1
  }
  $count = 0
  foreach ($line in $Lines) {
    if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
      $count++
    }
  }
  return $count
}

function Read-LogLinesWithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [int]$Retries,
    [Parameter(Mandatory = $true)]
    [int]$DelayMs
  )

  for ($i = 0; $i -le $Retries; $i++) {
    $lines = Read-AllLinesUtf8BestEffort -Path $Path
    $count = Get-LineCountSafe -Lines $lines
    if ($count -gt 0) {
      return $lines
    }
    if ($i -lt $Retries) {
      Start-Sleep -Milliseconds $DelayMs
    }
  }
  return $lines
}

function Get-LogSnapshot {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$PrimaryLogPath = "",
    [Parameter(Mandatory = $true)]
    [string]$GameModsDir,
    [Parameter(Mandatory = $true)]
    [bool]$SkipGameLogs,
    [Parameter(Mandatory = $true)]
    [int]$LogMaxAgeMinutes,
    [Parameter(Mandatory = $true)]
    [int]$LogReadRetryCount,
    [Parameter(Mandatory = $true)]
    [int]$LogReadRetryDelayMs
  )

  $resolvedPrimary = Get-LatestTLauncherLogPathOrNull -PreferredPath $PrimaryLogPath
  $additionalLogPaths = @()
  if (-not $SkipGameLogs -and [string]::IsNullOrWhiteSpace($PrimaryLogPath)) {
    $additionalLogPaths = Get-AdditionalGameLogPaths -GameModsDir $GameModsDir
    $additionalLogPaths = Select-RecentLogPaths -Paths $additionalLogPaths -MaxAgeMinutes $LogMaxAgeMinutes
  }
  $resolvedLogPaths = Resolve-LogPaths -PrimaryPath $resolvedPrimary -AdditionalPaths $additionalLogPaths
  $resolvedLogPaths = @($resolvedLogPaths)

  $logLinesBySource = @{}
  foreach ($logPath in $resolvedLogPaths) {
    if (-not (Test-Path -LiteralPath $logPath)) { continue }
    $lines = Read-LogLinesWithRetry -Path $logPath -Retries $LogReadRetryCount -DelayMs $LogReadRetryDelayMs
    if ($lines -is [string]) {
      $lines = @($lines)
    }
    if ($null -eq $lines) {
      $lines = @()
    }
    $lines = $lines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    $logLinesBySource[$logPath] = $lines
  }

  $allLogLines = @()
  foreach ($logPath in $logLinesBySource.Keys) {
    $allLogLines += $logLinesBySource[$logPath]
  }

  return [pscustomobject]@{
    PrimaryLog = $resolvedPrimary
    Logs = $resolvedLogPaths
    Lines = $allLogLines
    LineCount = (Get-LineCountSafe -Lines $allLogLines)
  }
}

function Get-IncompatibleModIdsFromLog {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines,
    [Parameter(Mandatory = $true)]
    [bool]$IncludeWarnMixins
  )

  $ids = @{}
  $fromModSeverityRegex = if ($IncludeWarnMixins) { "(ERROR|WARN)" } else { "ERROR" }
  $mixinApplySeverityRegex = "(ERROR|WARN)"
  $fromModPattern = "^\[.*?\]\s+\[.*?\/" + $fromModSeverityRegex + "\]:\s+.*?\bfrom mod\s+(?<id>[a-z0-9_\-\.]+)\b"
  $mixinApplyPattern = "^\[.*?\]\s+\[.*?\/" + $mixinApplySeverityRegex + "\]:\s+Mixin apply for mod\s+(?<id>[a-z0-9_\-\.]+)\s+failed\b"
  $crashReportModPattern = "^(?!\[).*(failed|Critical injection|InjectionError|Mixin transformation).*\bfrom mod\s+(?<id>[a-z0-9_\-\.]+)\b"
  $crashProvidedByPattern = "^(?!\[).*\bprovided by\s+['""](?<id>[a-z0-9_\-\.]+)['""]"
  $requiresPattern1 = "^\[.*?\]\s+\[.*?\/ERROR\]:\s+Mod\s+(?<id>[a-z0-9_\-\.]+)\s+requires\b"
  $requiresPattern2 = "^\[.*?\]\s+\[.*?\/ERROR\]:\s+Could not find required mod:\s+(?<id>[a-z0-9_\-\.]+)\b"
  $incompatibleDetailPattern = '(requires|required|incompatible|not compatible|depends|needs|was built for|requires version|requires minecraft|requires fabric|requires fabricloader|requires loader)'
  $modNamedErrorPattern = '^\[.*?\]\s+\[.*?/(ERROR|WARN)\]:\s+Mod\s+[''"]?.*?[''"]?\s+\((?<id>[a-z0-9_\-\.]+)\)\b(?<detail>.*)$'
  $modNamedListPattern = '^\s*-\s+Mod\s+[''"]?.*?[''"]?\s+\((?<id>[a-z0-9_\-\.]+)\)\b(?<detail>.*)$'
  $modBareErrorPattern = '^\[.*?\]\s+\[.*?/(ERROR|WARN)\]:\s+Mod\s+(?<id>[a-z0-9_\-\.]+)\b(?<detail>.*)$'

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, $mixinApplyPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $fromModPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $requiresPattern1, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $requiresPattern2, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $modNamedErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $modBareErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $modNamedListPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $detail = $m.Groups["detail"].Value
      if ($detail -match $incompatibleDetailPattern) {
        $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
        continue
      }
    }

    $m = [regex]::Match($line, $crashReportModPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $crashProvidedByPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }
  }

  if ($ids.Count -eq 0) { return @() }
  # ! Use unary comma to prevent single-element unwrapping (avoids missing .Count on callers).
  return ,@($ids.Keys | Sort-Object)
}

function Get-FabricModIdsFromJar {
  <#
  .SYNOPSIS
  Reads fabric.mod.json from the jar to extract mod IDs.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarPath
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = $null
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    $entry = $zip.Entries | Where-Object { $_.FullName -eq "fabric.mod.json" } | Select-Object -First 1
    if (-not $entry) { return @() }
    $sr = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8, $true)
    try {
      $jsonText = $sr.ReadToEnd()
    } finally {
      $sr.Dispose()
    }
    $obj = $jsonText | ConvertFrom-Json -ErrorAction Stop
    $ids = @{}
    if ($null -ne $obj.id -and -not [string]::IsNullOrWhiteSpace([string]$obj.id)) {
      $ids[[string]$obj.id.ToLowerInvariant()] = $true
    }
    if ($null -ne $obj.provides) {
      if ($obj.provides -is [string]) {
        $value = [string]$obj.provides
        if (-not [string]::IsNullOrWhiteSpace($value)) {
          $ids[$value.ToLowerInvariant()] = $true
        }
      } else {
        foreach ($entryId in $obj.provides) {
          $value = [string]$entryId
          if (-not [string]::IsNullOrWhiteSpace($value)) {
            $ids[$value.ToLowerInvariant()] = $true
          }
        }
      }
    }
    if ($ids.Count -eq 0) { return @() }
    # ! Use unary comma to prevent single-element unwrapping.
    return ,@($ids.Keys)
  } catch {
    return @()
  } finally {
    if ($zip) { $zip.Dispose() }
  }
}

function Get-FabricRequiringModIds {
  <#
  .SYNOPSIS
  Extracts mod IDs that REQUIRE missing dependencies (the mod to blame, not the missing dep).
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  $ids = @{}
  # * Pattern: "Mod 'Name' (mod-id) X.Y.Z requires version ... of dependency, which is missing!"
  # * Accepts versions like "1.4.1+1.21.7" and list-style lines like "- Mod 'Bonded' ...".
  $fabricRequiresPattern = "^\s*(?:-\s+)?Mod\s+['""]?[^'""]+['""]?\s+\((?<id>[a-z0-9_\-\.]+)\)\s+\S+\s+requires\s+"

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, $fabricRequiresPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
    }
  }

  if ($ids.Count -eq 0) { return @() }
  # ! Use unary comma to prevent single-element unwrapping (avoids missing .Count on callers).
  return ,@($ids.Keys | Sort-Object)
}

function Get-FabricMissingDependencyIds {
  <#
  .SYNOPSIS
  Extracts missing dependency mod IDs from Fabric logs/dialog text.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  $ids = @{}
  # * Pattern: "... requires version ... of libjf-base, which is missing!"
  $requiresMissingPattern = "requires\s+version\s+.+?\s+of\s+(?<id>[a-z0-9_\-\.]+),\s+which\s+is\s+missing"
  # * Pattern: "Could not find required mod: libjf-base"
  $couldNotFindPattern = "Could not find required mod:\s+(?<id>[a-z0-9_\-\.]+)\b"
  # * Pattern: "owo-lib is required to run the following mods"
  $requiredToRunPattern = "(?<id>[a-z0-9_\-\.]+)\s+is\s+required\s+to\s+run\s+the\s+following\s+mods?\b"

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, $requiresMissingPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }
    $m = [regex]::Match($line, $couldNotFindPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }
    $m = [regex]::Match($line, $requiredToRunPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }
  }

  if ($ids.Count -eq 0) { return @() }
  return ,@($ids.Keys | Sort-Object)
}

function Test-AnyIdOverlap {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$IdsA = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$IdsB = @()
  )

  if (-not $IdsA -or $IdsA.Count -eq 0) { return $false }
  if (-not $IdsB -or $IdsB.Count -eq 0) { return $false }
  $set = @{}
  foreach ($id in $IdsA) { $set[$id.ToLowerInvariant()] = $true }
  foreach ($id in $IdsB) {
    if ($set.ContainsKey($id.ToLowerInvariant())) { return $true }
  }
  return $false
}

function Test-JarNameMatchesAnyId {
  <#
  .SYNOPSIS
  Best-effort match: checks whether a jar file name likely corresponds to a dependency id.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarName,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$Ids = @()
  )

  if ([string]::IsNullOrWhiteSpace($JarName)) { return $false }
  if (-not $Ids -or $Ids.Count -eq 0) { return $false }

  $name = $JarName.ToLowerInvariant()
  foreach ($id in $Ids) {
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $idLower = $id.ToLowerInvariant()
    if ($name -like ("*{0}*" -f $idLower)) { return $true }

    # * Token match for cases like: missing dep "libjf-base" vs jar "libjf-3.19.3+backport.jar".
    $tokens = $idLower -split "[-_\\.]"
    foreach ($t in $tokens) {
      if ($t.Length -lt 3) { continue }
      if ($name -like ("*{0}*" -f $t)) { return $true }
    }
  }
  return $false
}

function Find-ModJarsByIds {
  <#
  .SYNOPSIS
  Finds jar files that provide the given mod IDs.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModsDir,
    [Parameter(Mandatory = $true)]
    [string[]]$ModIds
  )

  if (-not $ModIds -or $ModIds.Count -eq 0) { return @() }

  $idSet = @{}
  foreach ($id in $ModIds) {
    $idSet[$id.ToLowerInvariant()] = $true
  }

  $foundJars = New-Object System.Collections.Generic.List[object]
  $jars = Get-ChildItem -LiteralPath $ModsDir -Filter "*.jar" -File -ErrorAction SilentlyContinue
  foreach ($jar in $jars) {
    $jarIds = Get-FabricModIdsFromJar -JarPath $jar.FullName
    if (-not $jarIds) { continue }
    foreach ($jarId in $jarIds) {
      if ($idSet.ContainsKey($jarId.ToLowerInvariant())) {
        $foundJars.Add($jar)
        break
      }
    }
  }

  return ,$foundJars.ToArray()
}

function Find-ModJarsByIdsBestEffort {
  <#
  .SYNOPSIS
  Finds jar files for mod IDs using metadata first, then filename heuristics.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModsDir,
    [Parameter(Mandatory = $true)]
    [string[]]$ModIds
  )

  if (-not $ModIds -or $ModIds.Count -eq 0) { return @() }

  $byMetadata = Find-ModJarsByIds -ModsDir $ModsDir -ModIds $ModIds
  if ($byMetadata -and $byMetadata.Count -gt 0) {
    return ,@($byMetadata | Sort-Object -Property FullName -Unique)
  }

  # * Fallback: match jar filenames against the ids/tokens (for edge cases where fabric.mod.json is missing/unreadable).
  $matched = New-Object System.Collections.Generic.List[object]
  $jars = Get-ChildItem -LiteralPath $ModsDir -Filter "*.jar" -File -ErrorAction SilentlyContinue
  foreach ($jar in $jars) {
    if (Test-JarNameMatchesAnyId -JarName $jar.Name -Ids $ModIds) {
      $matched.Add($jar)
    }
  }
  if ($matched.Count -eq 0) { return @() }
  return ,@($matched.ToArray() | Sort-Object -Property FullName -Unique)
}

function ConvertTo-NormalizedLogLine {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Line
  )

  $text = $Line.Trim()
  $text = [regex]::Replace($text, "^\[[^\]]+\]\s+\[[^\]]+\]:\s+", "")
  $text = [regex]::Replace($text, "^\[[^\]]+\]:\s+", "")
  $text = [regex]::Replace($text, "\s+", " ")
  return $text
}

function Select-ErrorEvidenceLines {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines,
    [Parameter(Mandatory = $true)]
    [int]$MaxLines
  )

  $selected = New-Object System.Collections.Generic.List[string]
  if ($MaxLines -le 0) { return $selected }

  $pattern = "(ERROR|Exception|Caused by|Mixin apply|InjectionError|Critical injection|Crash Report|crash report|from mod|Could not find required mod|requires\b)"

  # * Collect deterministically: normalize -> unique -> sort -> take N.
  $unique = @{}
  foreach ($line in $Lines) {
    if ($line -match $pattern) {
      $norm = ConvertTo-NormalizedLogLine -Line $line
      if (-not [string]::IsNullOrWhiteSpace($norm)) {
        $unique[$norm] = $true
      }
    }
  }
  if ($unique.Count -eq 0) { return $selected }
  foreach ($norm in ($unique.Keys | Sort-Object)) {
    $selected.Add($norm)
    if ($selected.Count -ge $MaxLines) { break }
  }

  return $selected
}

function Get-MinecraftVersionFromLog {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, "Loading Minecraft\s+(?<ver>\S+)\s+with Fabric Loader", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) { return $m.Groups["ver"].Value }
  }

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, "^\s*-\s+minecraft\s+(?<ver>\S+)\s*$", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) { return $m.Groups["ver"].Value }
  }

  return "unknown"
}

function Get-ErrorSignature {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines,
    [Parameter(Mandatory = $true)]
    [int]$MaxLines,
    [Parameter(Mandatory = $true)]
    [bool]$IncludeWarnMixins
  )

  $safeLines = @($Lines)
  $parts = New-Object System.Collections.Generic.List[string]
  $modIds = @(Get-IncompatibleModIdsFromLog -Lines $safeLines -IncludeWarnMixins $IncludeWarnMixins)
  if ($modIds.Count -eq 1 -and $null -ne $modIds[0] -and ($modIds[0] -is [System.Collections.IEnumerable]) -and -not ($modIds[0] -is [string])) {
    $modIds = @($modIds[0])
  }
  $modIds = @($modIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($modIds.Count -gt 0) {
    $parts.Add(("mods: {0}" -f ($modIds -join ", ")))
  }

  $evidenceLines = @(Select-ErrorEvidenceLines -Lines $safeLines -MaxLines $MaxLines)
  if ($evidenceLines.Count -gt 0) {
    $parts.Add(("lines: {0}" -f ($evidenceLines -join " | ")))
  }

  if ($parts.Count -eq 0) { return "" }
  return ($parts -join "; ")
}

function Get-ErrorEvidenceKey {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines,
    [Parameter(Mandatory = $true)]
    [int]$MaxLines
  )

  $safeLines = @($Lines)
  $evidenceLines = @(Select-ErrorEvidenceLines -Lines $safeLines -MaxLines $MaxLines)
  if (-not $evidenceLines -or $evidenceLines.Count -eq 0) { return "" }

  $norm = @()
  foreach ($l in $evidenceLines) {
    $v = [string]$l
    if ([string]::IsNullOrWhiteSpace($v)) { continue }
    $norm += @($v.Trim())
  }
  if (-not $norm -or $norm.Count -eq 0) { return "" }
  return ($norm -join " | ")
}

function Test-SignatureChanged {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Baseline,
    [Parameter(Mandatory = $true)]
    [string]$Current,
    [Parameter(Mandatory = $false)]
    [string]$BaselineEvidenceKey = "",
    [Parameter(Mandatory = $false)]
    [string]$CurrentEvidenceKey = "",
    [Parameter(Mandatory = $false)]
    [bool]$IgnoreModsWhenEvidencePresent = $true
  )

  # * Prefer evidence-line comparison when available to avoid false positives caused by
  # * changes in Fabric's "incompatible mods" listing (dependency cascades).
  if ($IgnoreModsWhenEvidencePresent -and (-not [string]::IsNullOrWhiteSpace($BaselineEvidenceKey) -or -not [string]::IsNullOrWhiteSpace($CurrentEvidenceKey))) {
    if ([string]::IsNullOrWhiteSpace($BaselineEvidenceKey)) { return $true }
    if ([string]::IsNullOrWhiteSpace($CurrentEvidenceKey)) { return $true }
    return -not [string]::Equals($BaselineEvidenceKey, $CurrentEvidenceKey, [System.StringComparison]::OrdinalIgnoreCase)
  }

  if ([string]::IsNullOrWhiteSpace($Baseline)) {
    return (-not [string]::IsNullOrWhiteSpace($Current))
  }
  if ([string]::IsNullOrWhiteSpace($Current)) { return $true }
  return -not [string]::Equals($Baseline, $Current, [System.StringComparison]::OrdinalIgnoreCase)
}

function Move-ToQuarantine {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [Parameter(Mandatory = $true)]
    [string]$DestDir,
    [Parameter(Mandatory = $true)]
    [bool]$IsDryRun,
    [Parameter(Mandatory = $true)]
    [int]$Retries,
    [Parameter(Mandatory = $true)]
    [int]$DelayMs
  )

  if (-not (Test-Path -LiteralPath $SourcePath)) {
    return $null
  }
  if ($IsDryRun) {
    return ("DRYRUN move: {0} -> {1}" -f $SourcePath, $DestDir)
  }
  New-DirectoryIfMissing -DirPath $DestDir
  $destPath = Join-Path -Path $DestDir -ChildPath ([System.IO.Path]::GetFileName($SourcePath))
  for ($i = 0; $i -le $Retries; $i++) {
    try {
      Move-Item -LiteralPath $SourcePath -Destination $destPath -Force -ErrorAction Stop
      return $destPath
    } catch [System.IO.IOException] {
      if ($i -ge $Retries) { throw }
      Start-Sleep -Milliseconds $DelayMs
      continue
    } catch {
      throw
    }
  }
  return $destPath
}

function Restore-FromQuarantine {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [Parameter(Mandatory = $true)]
    [string]$DestDir,
    [Parameter(Mandatory = $true)]
    [bool]$IsDryRun,
    [Parameter(Mandatory = $true)]
    [bool]$AllowOverwrite
  )

  if (-not (Test-Path -LiteralPath $SourcePath)) {
    return $null
  }
  if ($IsDryRun) {
    return ("DRYRUN restore: {0} -> {1}" -f $SourcePath, $DestDir)
  }
  New-DirectoryIfMissing -DirPath $DestDir
  $destPath = Join-Path -Path $DestDir -ChildPath ([System.IO.Path]::GetFileName($SourcePath))
  if ((Test-Path -LiteralPath $destPath) -and (-not $AllowOverwrite)) {
    return ("restore skipped (exists): {0}" -f $destPath)
  }
  Move-Item -LiteralPath $SourcePath -Destination $destPath -Force -ErrorAction Stop
  return $destPath
}

function Get-MovedItemByJarName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarName
  )

  foreach ($item in $movedItems) {
    if ($null -eq $item) { continue }
    if ([string]$item.JarName -eq $JarName) { return $item }
  }
  return $null
}

function Update-QuarantineState {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$DesiredJarNames,
    [Parameter(Mandatory = $false)]
    [string[]]$PinnedJarNames = @()
  )

  $desiredSet = @{}
  foreach ($name in $PinnedJarNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $desiredSet[$name.ToLowerInvariant()] = $name
  }
  foreach ($name in $DesiredJarNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $desiredSet[$name.ToLowerInvariant()] = $name
  }

  foreach ($item in $movedItems) {
    if ($null -eq $item) { continue }
    $jarName = [string]$item.JarName
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
    $key = $jarName.ToLowerInvariant()
    if ($desiredSet.ContainsKey($key)) { continue }

    if ($null -ne $item.GameQuarantine -and (Test-Path -LiteralPath $item.GameQuarantine)) {
      $restoreGame = Restore-FromQuarantine -SourcePath $item.GameQuarantine `
        -DestDir $GameModsDir `
        -IsDryRun $false `
        -AllowOverwrite ([bool]$ForceRestore)
      if ($restoreGame -and (-not (Test-Path -LiteralPath $item.GameQuarantine))) {
        $item.GameQuarantine = $null
      }
    }
    if ($useStorage -and $null -ne $item.StorageQuarantine -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
      $restoreStorage = Restore-FromQuarantine -SourcePath $item.StorageQuarantine `
        -DestDir $StorageModsDir `
        -IsDryRun $false `
        -AllowOverwrite ([bool]$ForceRestore)
      if ($restoreStorage -and (-not (Test-Path -LiteralPath $item.StorageQuarantine))) {
        $item.StorageQuarantine = $null
      }
    }

    if ($movedJarNameSet.ContainsKey($jarName)) {
      $null = $movedJarNameSet.Remove($jarName)
    }
  }

  foreach ($key in $desiredSet.Keys) {
    $jarName = $desiredSet[$key]
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }

    $gamePath = Join-Path -Path $GameModsDir -ChildPath $jarName
    $storagePath = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $jarName } else { $null }
    $gameDest = $null
    $storageDest = $null

    if (Test-Path -LiteralPath $gamePath) {
      $gameDest = Move-ToQuarantine -SourcePath $gamePath -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
    }
    if ($useStorage -and $storagePath -and (Test-Path -LiteralPath $storagePath)) {
      $storageDest = Move-ToQuarantine -SourcePath $storagePath -DestDir $storageQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
    }

    if ($null -ne $gameDest -or $null -ne $storageDest) {
      $item = Get-MovedItemByJarName -JarName $jarName
      if ($null -eq $item) {
        $item = [pscustomobject]@{
            JarName = $jarName
            GameSource = $gamePath
            GameQuarantine = $gameDest
            StorageSource = if ($useStorage) { $storagePath } else { $null }
            StorageQuarantine = $storageDest
          }
        $movedItems.Add($item)
      } else {
        if ($gameDest) {
          $item.GameSource = $gamePath
          $item.GameQuarantine = $gameDest
        }
        if ($storageDest) {
          $item.StorageSource = if ($useStorage) { $storagePath } else { $null }
          $item.StorageQuarantine = $storageDest
        }
      }
      $movedJarNameSet[$jarName] = $true
    } else {
      $item = Get-MovedItemByJarName -JarName $jarName
      if ($null -ne $item -and (-not $movedJarNameSet.ContainsKey($jarName))) {
        $movedJarNameSet[$jarName] = $true
      }
    }
  }
}

# * Runs a single isolation probe and returns whether the test group matches the baseline issue.
function Invoke-IsolationProbe {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$TestJarNames,
    [Parameter(Mandatory = $true)]
    [string]$BaselineSignature,
    [Parameter(Mandatory = $true)]
    [string]$BaselineEvidenceKey,
    [Parameter(Mandatory = $false)]
    [string]$PhasePrefix = "isolation_probe",
    [Parameter(Mandatory = $false)]
    [string[]]$PinnedJarNames = @()
  )

  Update-QuarantineState -DesiredJarNames $TestJarNames -PinnedJarNames $PinnedJarNames

  if ([string]::IsNullOrWhiteSpace($PhasePrefix)) {
    $PhasePrefix = "isolation_probe"
  }

  $ignoreHandles = @()
  if ($script:lastOutcomeHandleId -ne 0) {
    $ignoreHandles = @($script:lastOutcomeHandleId)
  }

  $attemptStart = Get-Date
  $script:phase = ("{0}_invoke_launch" -f $PhasePrefix)
  $outcome = Invoke-LaunchAttempt -LauncherTitlePattern $LauncherWindowTitlePattern `
    -LauncherPath $LauncherExePath `
    -LauncherArgs $LauncherArguments `
    -AppendAutoLaunch ([bool]$UseAutoLaunch) `
    -LauncherTimeoutSeconds $LauncherWindowTimeoutSeconds `
    -ButtonNames $PlayButtonNames `
    -ClickOffsetX $PlayClickOffsetX `
    -ClickOffsetY $PlayClickOffsetY `
    -EnableEnterFallback $UseEnterFallback `
    -AllowBroadSearch ([bool]$EnableBroadUiSearch) `
    -CrashPatterns $CrashWindowTitlePatterns `
    -FabricPatterns $FabricWindowTitlePatterns `
    -OutcomeTimeoutSeconds $OutcomeTimeoutSeconds `
    -PollSeconds $PollIntervalSeconds `
    -IgnoreHandleIds $ignoreHandles

  if ($outcome.Type -ne "FabricDialog") {
    $fabricWindowNow = Select-WindowByTitlePatterns -Patterns $FabricWindowTitlePatterns
    if ($null -ne $fabricWindowNow) {
      Write-Host ("Detected Fabric dialog after outcome: {0}" -f $fabricWindowNow.Title) -ForegroundColor Yellow
      $outcome = [pscustomobject]@{
        Type = "FabricDialog"
        Window = $fabricWindowNow
      }
    }
  }

  Write-Host ("Outcome: {0}" -f $outcome.Type) -ForegroundColor $(if ($outcome.Type -eq "Timeout") { "Green" } else { "Yellow" })

  if ($outcome.Type -ne "Timeout" -and $null -ne $outcome.Window) {
    Write-Host ("Closing outcome window: {0} ({1})" -f $outcome.Type, $outcome.Window.Title) -ForegroundColor Gray
    $script:lastOutcomeHandleId = [long]$outcome.Window.Handle.ToInt64()
    $script:phase = ("{0}_close_outcome_window" -f $PhasePrefix)
    Close-OutcomeWindow -Outcome $outcome `
      -DelaySeconds $CrashCloseDelaySeconds `
      -OffsetX $CrashCloseClickOffsetX `
      -OffsetY $CrashCloseClickOffsetY

    $extraFabricWindow = Select-WindowByTitlePatterns -Patterns $FabricWindowTitlePatterns
    if ($null -ne $extraFabricWindow) {
      Write-Host ("Closing extra Fabric Loader dialog: {0}" -f $extraFabricWindow.Title) -ForegroundColor Gray
      Close-OutcomeWindow -Outcome ([pscustomobject]@{ Type = "FabricDialog"; Window = $extraFabricWindow }) `
        -DelaySeconds 0 `
        -OffsetX -1 `
        -OffsetY -1
    }

    if (Test-WindowStillExists -HandleId $script:lastOutcomeHandleId) {
      Write-Host ("Warning: outcome window did not close ({0}). It will be detected again on next attempt." -f $outcome.Type) -ForegroundColor Yellow
      $script:lastOutcomeHandleId = 0
    }
  }

  if ($outcome.Type -ne "Timeout") {
    $script:phase = ("{0}_wait_game_exit" -f $PhasePrefix)
    $exited = Wait-ForGameProcessesToExit -Names $GameProcessNames `
      -StartedAfter $attemptStart `
      -TimeoutSeconds $WaitForGameExitSeconds `
      -PollSeconds $GameExitPollSeconds
    if (-not $exited) {
      Write-Host ("Warning: game processes still running after {0}s. Next file move may fail due to locks." -f $WaitForGameExitSeconds) -ForegroundColor Yellow
    }
  }

  if ($outcome.Type -eq "FabricDialog") {
    Start-Sleep -Seconds $LogPostRunDelaySeconds
    $script:phase = ("{0}_read_dependency_logs" -f $PhasePrefix)
    $snapshot = Get-LogSnapshot -PrimaryLogPath $LogPath `
      -GameModsDir $GameModsDir `
      -SkipGameLogs ([bool]$SkipGameLogs) `
      -LogMaxAgeMinutes $LogMaxAgeMinutes `
      -LogReadRetryCount $LogReadRetryCount `
      -LogReadRetryDelayMs $LogReadRetryDelayMs
    $requiringModIds = @(Get-FabricRequiringModIds -Lines $snapshot.Lines) |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    $missingDepIds = @(Get-FabricMissingDependencyIds -Lines $snapshot.Lines) |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    [void](Wait-ForLauncherWindowInteractive -TitlePattern $LauncherWindowTitlePattern `
        -CrashPatterns $CrashWindowTitlePatterns `
        -FabricPatterns $FabricWindowTitlePatterns `
        -PollSeconds $PollIntervalSeconds)
    return [pscustomobject]@{
      Outcome = $outcome
      GroupMatches = $false
      Mode = "DependencyDialog"
      RequiringModIds = @($requiringModIds)
      MissingDepIds = @($missingDepIds)
    }
  }

  $groupMatches = $false
  if ($outcome.Type -eq "Timeout") {
    $groupMatches = $true
  } else {
    Start-Sleep -Seconds $LogPostRunDelaySeconds
    $script:phase = ("{0}_read_logs" -f $PhasePrefix)
    $snapshot = Get-LogSnapshot -PrimaryLogPath $LogPath `
      -GameModsDir $GameModsDir `
      -SkipGameLogs ([bool]$SkipGameLogs) `
      -LogMaxAgeMinutes $LogMaxAgeMinutes `
      -LogReadRetryCount $LogReadRetryCount `
      -LogReadRetryDelayMs $LogReadRetryDelayMs

    if ($script:mcVersionForLegacy -eq "unknown") {
      $script:mcVersionForLegacy = Get-MinecraftVersionFromLog -Lines $snapshot.Lines
    }

    $signature = Get-ErrorSignature -Lines $snapshot.Lines `
      -MaxLines $ErrorSignatureLineLimit `
      -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
    $evidenceKey = Get-ErrorEvidenceKey -Lines $snapshot.Lines -MaxLines $ErrorSignatureLineLimit

    Write-Verbose ("Signature: {0}" -f $signature)
    $signatureChanged = Test-SignatureChanged -Baseline $BaselineSignature -Current $signature `
      -BaselineEvidenceKey $BaselineEvidenceKey -CurrentEvidenceKey $evidenceKey `
      -IgnoreModsWhenEvidencePresent ([bool]$IgnoreModListForSignatureChange)
    if ($signatureChanged) {
      Start-Sleep -Milliseconds 750
      $confirmSnapshot = Get-LogSnapshot -PrimaryLogPath $LogPath `
        -GameModsDir $GameModsDir `
        -SkipGameLogs ([bool]$SkipGameLogs) `
        -LogMaxAgeMinutes $LogMaxAgeMinutes `
        -LogReadRetryCount $LogReadRetryCount `
        -LogReadRetryDelayMs $LogReadRetryDelayMs
      $confirmSignature = Get-ErrorSignature -Lines $confirmSnapshot.Lines `
        -MaxLines $ErrorSignatureLineLimit `
        -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
      $confirmEvidenceKey = Get-ErrorEvidenceKey -Lines $confirmSnapshot.Lines -MaxLines $ErrorSignatureLineLimit
      if (-not (Test-SignatureChanged -Baseline $BaselineSignature -Current $confirmSignature `
          -BaselineEvidenceKey $BaselineEvidenceKey -CurrentEvidenceKey $confirmEvidenceKey `
          -IgnoreModsWhenEvidencePresent ([bool]$IgnoreModListForSignatureChange))) {
        Write-Verbose "Signature change not confirmed; treating as unchanged."
        $signatureChanged = $false
      }
    }
    $groupMatches = $signatureChanged
  }

  [void](Wait-ForLauncherWindowInteractive -TitlePattern $LauncherWindowTitlePattern `
      -CrashPatterns $CrashWindowTitlePatterns `
      -FabricPatterns $FabricWindowTitlePatterns `
      -PollSeconds $PollIntervalSeconds)

  return [pscustomobject]@{
    Outcome = $outcome
    GroupMatches = $groupMatches
    Mode = "Ok"
  }
}

# * Handles Fabric dependency dialogs by restoring removed deps and quick-isolating requiring mods.
function Invoke-FabricDependencyRecovery {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$RequiringModIds,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$MissingDepIds,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$RemovedJarNames,
    [Parameter(Mandatory = $true)]
    [hashtable]$PinnedJarNameSet,
    [Parameter(Mandatory = $true)]
    [hashtable]$ProtectedJarNameSet
  )

  $changes = $false
  $pinnedAdded = New-Object System.Collections.Generic.List[string]
  $protectedAdded = New-Object System.Collections.Generic.List[string]

  $requiringArr = @($RequiringModIds)
  $missingArr = @($MissingDepIds)
  $requiringLabel = if ($requiringArr.Count -gt 0) { $requiringArr -join ", " } else { "<none>" }
  $missingLabel = if ($missingArr.Count -gt 0) { $missingArr -join ", " } else { "<none>" }
  Write-Host ("Fabric dialog info. Requiring mods: {0}; Missing deps: {1}" -f $requiringLabel, $missingLabel) -ForegroundColor Gray

  $removedArr = @($RemovedJarNames)
  if ($missingArr.Count -gt 0 -and $removedArr.Count -gt 0) {
    foreach ($jarName in $removedArr) {
      if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
      $key = $jarName.ToLowerInvariant()
      if ($ProtectedJarNameSet.ContainsKey($key)) { continue }

      $removedItem = Get-MovedItemByJarName -JarName $jarName
      if ($null -eq $removedItem) { continue }

      $removedJarProvides = @()
      if ($null -ne $removedItem.GameQuarantine -and (Test-Path -LiteralPath $removedItem.GameQuarantine)) {
        $removedJarProvides = Get-FabricModIdsFromJar -JarPath $removedItem.GameQuarantine
      }
      $removedJarProvidesArr = @($removedJarProvides)

      $isLikelyRemovedDep = $false
      if ($removedJarProvidesArr.Count -gt 0) {
        $isLikelyRemovedDep = Test-AnyIdOverlap -IdsA $removedJarProvidesArr -IdsB $missingArr
      }
      if (-not $isLikelyRemovedDep) {
        $isLikelyRemovedDep = Test-JarNameMatchesAnyId -JarName $jarName -Ids $missingArr
      }
      if (-not $isLikelyRemovedDep) { continue }

      Write-Host ("Fabric missing dependency '{0}' appears caused by removing '{1}'. Restoring dependency." -f ($missingArr -join ", "), $jarName) -ForegroundColor Cyan

      if ($null -ne $removedItem.GameQuarantine -and (Test-Path -LiteralPath $removedItem.GameQuarantine)) {
        [void](Restore-FromQuarantine -SourcePath $removedItem.GameQuarantine -DestDir $GameModsDir -IsDryRun $false -AllowOverwrite $true)
        $removedItem.GameQuarantine = $null
      }
      if ($useStorage -and $null -ne $removedItem.StorageQuarantine -and (Test-Path -LiteralPath $removedItem.StorageQuarantine)) {
        [void](Restore-FromQuarantine -SourcePath $removedItem.StorageQuarantine -DestDir $StorageModsDir -IsDryRun $false -AllowOverwrite $true)
        $removedItem.StorageQuarantine = $null
      }
      if ($movedJarNameSet.ContainsKey($jarName)) {
        $null = $movedJarNameSet.Remove($jarName)
      }

      $ProtectedJarNameSet[$key] = $jarName
      $protectedAdded.Add($jarName)
      $changes = $true
    }
  }

  if ($requiringArr.Count -gt 0) {
    Write-Host ("Fabric dialog detected. Quick-isolating requiring mods: {0}" -f ($requiringArr -join ", ")) -ForegroundColor Cyan
    $culpritJars = Find-ModJarsByIdsBestEffort -ModsDir $GameModsDir -ModIds $requiringArr
    if ($culpritJars -and $culpritJars.Count -gt 0) {
      foreach ($cj in $culpritJars) {
        if ($movedJarNameSet.ContainsKey($cj.Name)) { continue }

        Write-Host ("Quick-isolating: {0}" -f $cj.Name) -ForegroundColor Cyan
        $script:phase = "quick_isolate_move"
        $qDest = Move-ToQuarantine -SourcePath $cj.FullName -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
        if ($null -ne $qDest) {
          $movedItems.Add([pscustomobject]@{
              JarName = $cj.Name
              GameSource = $cj.FullName
              GameQuarantine = $qDest
              StorageSource = $null
              StorageQuarantine = $null
            })
          $movedJarNameSet[$cj.Name] = $true
          $PinnedJarNameSet[$cj.Name.ToLowerInvariant()] = $cj.Name
          $pinnedAdded.Add($cj.Name)
          $changes = $true
        }
      }
    } else {
      Write-Host ("Warning: could not resolve requiring mod jar(s) for ids: {0}. Continuing isolation." -f ($requiringArr -join ", ")) -ForegroundColor Yellow
    }
  }

  return [pscustomobject]@{
    Changes = $changes
    PinnedAdded = @($pinnedAdded.ToArray() | Sort-Object -Unique)
    ProtectedAdded = @($protectedAdded.ToArray() | Sort-Object -Unique)
  }
}

function Invoke-BinaryIsolation {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Mods,
    [Parameter(Mandatory = $true)]
    [string]$BaselineSignature,
    [Parameter(Mandatory = $true)]
    [string]$BaselineEvidenceKey,
    [Parameter(Mandatory = $false)]
    [string[]]$PinnedJarNames = @()
  )

  $pinnedJarNameSet = @{}
  foreach ($name in $PinnedJarNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $pinnedJarNameSet[$name.ToLowerInvariant()] = $name
  }
  $protectedJarNameSet = @{}

  $remaining = @($Mods)
  if ($pinnedJarNameSet.Count -gt 0) {
    $remaining = @($remaining | Where-Object { -not $pinnedJarNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
  }
  if (-not $remaining -or $remaining.Count -eq 0) {
    return [pscustomobject]@{
      Mode = "ContinueLinear"
      Remaining = @()
      Reason = "empty"
    }
  }

  $attemptIndex = 0
  while ($remaining.Count -gt $BinaryLinearThreshold) {
    if ($remaining.Count -le 1) { break }

    $attemptIndex++
    $halfCount = [Math]::Ceiling($remaining.Count / 2)
    $testGroup = @($remaining | Select-Object -First $halfCount)
    $otherGroup = @($remaining | Select-Object -Skip $halfCount)
    if (-not $otherGroup -or $otherGroup.Count -eq 0) { break }

    Write-Host ("Binary isolation attempt {0}: testing {1} mod(s)" -f $attemptIndex, $testGroup.Count) -ForegroundColor Cyan

    $testNames = @($testGroup | ForEach-Object { $_.Name })
    $pinnedJarNames = @($pinnedJarNameSet.Values)
    $probeResult = Invoke-IsolationProbe -TestJarNames $testNames `
      -BaselineSignature $BaselineSignature `
      -BaselineEvidenceKey $BaselineEvidenceKey `
      -PhasePrefix "binary_attempt" `
      -PinnedJarNames $pinnedJarNames

    if ($probeResult.Mode -eq "DependencyDialog") {
      $recovery = Invoke-FabricDependencyRecovery -RequiringModIds $probeResult.RequiringModIds `
        -MissingDepIds $probeResult.MissingDepIds `
        -RemovedJarNames $testNames `
        -PinnedJarNameSet $pinnedJarNameSet `
        -ProtectedJarNameSet $protectedJarNameSet
      if ($recovery.Changes) {
        $pinnedJarNames = @($pinnedJarNameSet.Values)
        Update-QuarantineState -DesiredJarNames @() -PinnedJarNames $pinnedJarNames
        $remaining = @($remaining | Where-Object {
            $key = $_.Name.ToLowerInvariant()
            -not $pinnedJarNameSet.ContainsKey($key) -and -not $protectedJarNameSet.ContainsKey($key)
          })
        if (-not $remaining -or $remaining.Count -eq 0) {
          return [pscustomobject]@{
            Mode = "ContinueLinear"
            Remaining = @()
            Reason = "dependency_recovery_empty"
          }
        }
        continue
      }
      Write-Host "Warning: dependency dialog detected but no recovery actions were taken. Continuing binary refinement." -ForegroundColor Yellow
      $groupMatches = $false
    } else {
      $groupMatches = [bool]$probeResult.GroupMatches
    }

    if ($groupMatches) {
      $remaining = $testGroup
    } else {
      $remaining = $otherGroup
    }
  }

  $pinnedJarNames = @($pinnedJarNameSet.Values)
  Update-QuarantineState -DesiredJarNames @() -PinnedJarNames $pinnedJarNames
  return [pscustomobject]@{
    Mode = "ContinueLinear"
    Remaining = $remaining
    Reason = "threshold"
  }
}

function Invoke-ExponentialIsolation {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Mods,
    [Parameter(Mandatory = $true)]
    [string]$BaselineSignature,
    [Parameter(Mandatory = $true)]
    [string]$BaselineEvidenceKey,
    [Parameter(Mandatory = $false)]
    [string[]]$PinnedJarNames = @()
  )

  $pinnedJarNameSet = @{}
  foreach ($name in $PinnedJarNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $pinnedJarNameSet[$name.ToLowerInvariant()] = $name
  }
  $protectedJarNameSet = @{}

  $remaining = @($Mods)
  if ($pinnedJarNameSet.Count -gt 0) {
    $remaining = @($remaining | Where-Object { -not $pinnedJarNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
  }
  if (-not $remaining -or $remaining.Count -eq 0) {
    return [pscustomobject]@{
      Mode = "ContinueLinear"
      Remaining = @()
      Reason = "empty"
    }
  }

  $totalCount = $remaining.Count
  $probeMax = [Math]::Floor($totalCount / 2)
  if ($probeMax -lt 1) { $probeMax = 1 }
  if ($probeMax -gt $totalCount) { $probeMax = $totalCount }

  Write-Host ("Exponential probe max: {0}" -f $probeMax) -ForegroundColor Gray

  $probeSize = 1
  $previousSize = 0
  $attemptIndex = 0
  $selectedChunk = $null
  $selectedReason = "exponential_miss"

  while ($probeSize -le $probeMax) {
    if ($probeSize -gt $totalCount) { $probeSize = $totalCount }

    $attemptIndex++
    $testGroup = @($remaining | Select-Object -First $probeSize)
    if (-not $testGroup -or $testGroup.Count -eq 0) { break }

    Write-Host ("Exponential isolation attempt {0}: testing {1} mod(s)" -f $attemptIndex, $testGroup.Count) -ForegroundColor Cyan

    $testNames = @($testGroup | ForEach-Object { $_.Name })
    $pinnedJarNames = @($pinnedJarNameSet.Values)
    $probeResult = Invoke-IsolationProbe -TestJarNames $testNames `
      -BaselineSignature $BaselineSignature `
      -BaselineEvidenceKey $BaselineEvidenceKey `
      -PhasePrefix "exponential_attempt" `
      -PinnedJarNames $pinnedJarNames

    if ($probeResult.Mode -eq "DependencyDialog") {
      $recovery = Invoke-FabricDependencyRecovery -RequiringModIds $probeResult.RequiringModIds `
        -MissingDepIds $probeResult.MissingDepIds `
        -RemovedJarNames $testNames `
        -PinnedJarNameSet $pinnedJarNameSet `
        -ProtectedJarNameSet $protectedJarNameSet
      if ($recovery.Changes) {
        $pinnedJarNames = @($pinnedJarNameSet.Values)
        Update-QuarantineState -DesiredJarNames @() -PinnedJarNames $pinnedJarNames
        $remaining = @($remaining | Where-Object {
            $key = $_.Name.ToLowerInvariant()
            -not $pinnedJarNameSet.ContainsKey($key) -and -not $protectedJarNameSet.ContainsKey($key)
          })
        $totalCount = $remaining.Count
        if ($totalCount -eq 0) {
          return [pscustomobject]@{
            Mode = "ContinueLinear"
            Remaining = @()
            Reason = "dependency_recovery_empty"
          }
        }
        $probeMax = [Math]::Floor($totalCount / 2)
        if ($probeMax -lt 1) { $probeMax = 1 }
        if ($probeMax -gt $totalCount) { $probeMax = $totalCount }
        $probeSize = 1
        $previousSize = 0
        Write-Host ("Exponential isolation restarted after dependency recovery. Remaining: {0}" -f $totalCount) -ForegroundColor Gray
        continue
      }
      Write-Host "Warning: dependency dialog detected but no recovery actions were taken. Continuing exponential probing." -ForegroundColor Yellow
      $previousSize = $probeSize
      $probeSize = $probeSize * 2
      continue
    }

    if ([bool]$probeResult.GroupMatches) {
      $chunkSize = $probeSize - $previousSize
      if ($chunkSize -le 0) { $chunkSize = $probeSize }
      $selectedChunk = @($remaining | Select-Object -Skip $previousSize -First $chunkSize)
      $selectedReason = "exponential_match"
      break
    }

    $previousSize = $probeSize
    $probeSize = $probeSize * 2
  }

  if ($null -eq $selectedChunk) {
    $selectedChunk = @($remaining | Select-Object -Skip $previousSize)
  }

  if (-not $selectedChunk -or $selectedChunk.Count -eq 0) {
    $pinnedJarNames = @($pinnedJarNameSet.Values)
    Update-QuarantineState -DesiredJarNames @() -PinnedJarNames $pinnedJarNames
    return [pscustomobject]@{
      Mode = "ContinueLinear"
      Remaining = @()
      Reason = "empty"
    }
  }

  if ($selectedReason -eq "exponential_match") {
    Write-Host ("Exponential isolation selected last chunk: {0} mod(s)" -f $selectedChunk.Count) -ForegroundColor Gray
  } else {
    Write-Host ("Exponential isolation selected remaining group: {0} mod(s)" -f $selectedChunk.Count) -ForegroundColor Gray
  }

  $pinnedJarNames = @($pinnedJarNameSet.Values)
  $binaryResult = Invoke-BinaryIsolation -Mods $selectedChunk `
    -BaselineSignature $BaselineSignature `
    -BaselineEvidenceKey $BaselineEvidenceKey `
    -PinnedJarNames $pinnedJarNames
  return [pscustomobject]@{
    Mode = $binaryResult.Mode
    Remaining = $binaryResult.Remaining
    Reason = ("{0}/{1}" -f $selectedReason, $binaryResult.Reason)
  }
}

if (-not (Test-Path -LiteralPath $GameModsDir)) {
  throw ("GameModsDir not found: {0}" -f $GameModsDir)
}

$useStorage = -not [string]::IsNullOrWhiteSpace($StorageModsDir)
if ($useStorage -and (-not (Test-Path -LiteralPath $StorageModsDir))) {
  Write-Host ("Warning: StorageModsDir not found, storage operations are skipped: {0}" -f $StorageModsDir) -ForegroundColor Yellow
  $useStorage = $false
}

$candidateMods = @(Get-ChildItem -LiteralPath $GameModsDir -Filter "*.jar" -File -ErrorAction Stop |
    Sort-Object -Property LastWriteTime -Descending)

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

if ($DryRun) {
  foreach ($mod in $candidateMods) {
    Write-Host ("Plan: {0} ({1})" -f $mod.Name, $mod.LastWriteTime) -ForegroundColor Gray
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
$baselineSignature = ""
$baselineEvidenceKey = ""
$activeBaselineSignature = ""
$activeBaselineEvidenceKey = ""
$baselineOutcome = "Unknown"
$mcVersionForLegacy = "unknown"
$exitCode = 0
$culpritJarNames = @()
$culpritMoves = New-Object System.Collections.Generic.List[object]
$stopReason = ""
$hadError = $false
$lastOutcomeHandleId = 0
$baselineSucceeded = $false
$phase = "init"

function Write-ErrorDump {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetDir,
    [Parameter(Mandatory = $true)]
    [string]$Phase,
    [Parameter(Mandatory = $true)]
    $ErrorRecord
  )

  try {
    if ([string]::IsNullOrWhiteSpace($TargetDir)) { return $null }
    New-DirectoryIfMissing -DirPath $TargetDir
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $dumpPath = Join-Path -Path $TargetDir -ChildPath ("isolate-error-{0}.txt" -f $ts)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("timestamp: {0:o}" -f (Get-Date)))
    $lines.Add(("phase: {0}" -f $Phase))
    $lines.Add(("script: {0}" -f $PSCommandPath))
    $lines.Add(("ps: {0}" -f $PSVersionTable.PSVersion))
    $lines.Add(("cwd: {0}" -f (Get-Location)))
    $lines.Add("")
    $lines.Add("=== parameters ===")
    $lines.Add(("GameModsDir={0}" -f $GameModsDir))
    $lines.Add(("StorageModsDir={0}" -f $StorageModsDir))
    $lines.Add(("LogPath={0}" -f $LogPath))
    $lines.Add(("LauncherExePath={0}" -f $LauncherExePath))
    $lines.Add(("LauncherWindowTitlePattern={0}" -f $LauncherWindowTitlePattern))
    $lines.Add(("PlayClickOffsetX={0}" -f $PlayClickOffsetX))
    $lines.Add(("PlayClickOffsetY={0}" -f $PlayClickOffsetY))
    $lines.Add(("CrashCloseClickOffsetX={0}" -f $CrashCloseClickOffsetX))
    $lines.Add(("CrashCloseClickOffsetY={0}" -f $CrashCloseClickOffsetY))
    $lines.Add(("UseEnterFallback={0}" -f $UseEnterFallback))
    $lines.Add(("EnableBroadUiSearch={0}" -f $EnableBroadUiSearch))
    $lines.Add(("WaitForGameExitSeconds={0}" -f $WaitForGameExitSeconds))
    $lines.Add(("GameProcessNames={0}" -f ($GameProcessNames -join ",")))
    $lines.Add(("MoveRetryCount={0}" -f $MoveRetryCount))
    $lines.Add(("MoveRetryDelayMs={0}" -f $MoveRetryDelayMs))
    $lines.Add("")

    try {
      $lines.Add("=== visible windows (sample) ===")
      $windows = Get-WindowList
      $max = 40
      $count = 0
      foreach ($w in $windows) {
        $count++
        if ($count -gt $max) { break }
        $lines.Add(("[{0}] pid={1} handle=0x{2} title={3}" -f $count, $w.ProcessId, ("{0:X}" -f ([long]$w.Handle.ToInt64())), $w.Title))
      }
      if ($windows.Count -gt $max) {
        $lines.Add(("[...] total visible windows: {0}" -f $windows.Count))
      }
      $lines.Add("")
    } catch {
      $lines.Add("=== visible windows (sample) ===")
      $lines.Add("failed to enumerate windows")
      $lines.Add("")
    }

    $lines.Add("=== error record ===")
    $lines.Add(($ErrorRecord | Format-List * -Force | Out-String))
    if ($ErrorRecord.Exception) {
      $lines.Add("")
      $lines.Add("=== exception ===")
      $lines.Add(($ErrorRecord.Exception | Format-List * -Force | Out-String))
      $lines.Add("")
      $lines.Add("=== stacktrace ===")
      $lines.Add([string]$ErrorRecord.Exception.StackTrace)
    }
    if ($ErrorRecord.InvocationInfo) {
      $lines.Add("")
      $lines.Add("=== invocation ===")
      $lines.Add(($ErrorRecord.InvocationInfo | Format-List * -Force | Out-String))
      $lines.Add("")
      $lines.Add("=== position ===")
      $lines.Add([string]$ErrorRecord.InvocationInfo.PositionMessage)
    }

    $lines | Out-File -LiteralPath $dumpPath -Encoding UTF8
    return $dumpPath
  } catch {
    return $null
  }
}

try {
  if (-not $SkipBaselineRun) {
    Write-Host "Baseline attempt starting." -ForegroundColor Cyan
    $baselineAttemptStart = Get-Date
    $phase = "baseline_invoke_launch"
    $baselineOutcomeObj = Invoke-LaunchAttempt -LauncherTitlePattern $LauncherWindowTitlePattern `
      -LauncherPath $LauncherExePath `
      -LauncherArgs $LauncherArguments `
      -AppendAutoLaunch ([bool]$UseAutoLaunch) `
      -LauncherTimeoutSeconds $LauncherWindowTimeoutSeconds `
      -ButtonNames $PlayButtonNames `
      -ClickOffsetX $PlayClickOffsetX `
      -ClickOffsetY $PlayClickOffsetY `
      -EnableEnterFallback $UseEnterFallback `
      -AllowBroadSearch ([bool]$EnableBroadUiSearch) `
      -CrashPatterns $CrashWindowTitlePatterns `
      -FabricPatterns $FabricWindowTitlePatterns `
      -OutcomeTimeoutSeconds $OutcomeTimeoutSeconds `
      -PollSeconds $PollIntervalSeconds `
      -IgnoreHandleIds @()

    $baselineOutcome = $baselineOutcomeObj.Type
    Write-Host ("Baseline outcome: {0}" -f $baselineOutcome) -ForegroundColor $(if ($baselineOutcome -eq "Timeout") { "Green" } else { "Yellow" })
    if ($baselineOutcome -ne "Timeout") {
      if ($null -ne $baselineOutcomeObj.Window) {
        Write-Host ("Closing outcome window: {0} ({1})" -f $baselineOutcomeObj.Type, $baselineOutcomeObj.Window.Title) -ForegroundColor Gray
        $lastOutcomeHandleId = [long]$baselineOutcomeObj.Window.Handle.ToInt64()
        $phase = "baseline_close_outcome_window"
        Close-OutcomeWindow -Outcome $baselineOutcomeObj `
          -DelaySeconds $CrashCloseDelaySeconds `
          -OffsetX $CrashCloseClickOffsetX `
          -OffsetY $CrashCloseClickOffsetY
        # * Verify the window actually closed. If not, don't ignore it in future attempts.
        if (Test-WindowStillExists -HandleId $lastOutcomeHandleId) {
          Write-Host ("Warning: outcome window did not close ({0}). It will be detected again on next attempt." -f $baselineOutcomeObj.Type) -ForegroundColor Yellow
          $lastOutcomeHandleId = 0
        }
      }
      $phase = "baseline_wait_game_exit"
      $exited = Wait-ForGameProcessesToExit -Names $GameProcessNames `
        -StartedAfter $baselineAttemptStart `
        -TimeoutSeconds $WaitForGameExitSeconds `
        -PollSeconds $GameExitPollSeconds
      if (-not $exited) {
        Write-Host ("Warning: game processes still running after {0}s. File moves may fail due to locks." -f $WaitForGameExitSeconds) -ForegroundColor Yellow
      }
    } else {
      $baselineSucceeded = $true
    }
  }

  if (-not $baselineSucceeded) {
    Start-Sleep -Seconds $LogPostRunDelaySeconds
    $phase = "baseline_read_logs"
    $baselineSnapshot = Get-LogSnapshot -PrimaryLogPath $LogPath `
      -GameModsDir $GameModsDir `
      -SkipGameLogs ([bool]$SkipGameLogs) `
      -LogMaxAgeMinutes $LogMaxAgeMinutes `
      -LogReadRetryCount $LogReadRetryCount `
      -LogReadRetryDelayMs $LogReadRetryDelayMs

    $mcVersionForLegacy = Get-MinecraftVersionFromLog -Lines $baselineSnapshot.Lines

    $baselineSignature = Get-ErrorSignature -Lines $baselineSnapshot.Lines `
      -MaxLines $ErrorSignatureLineLimit `
      -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
    $baselineEvidenceKey = Get-ErrorEvidenceKey -Lines $baselineSnapshot.Lines -MaxLines $ErrorSignatureLineLimit
    $activeBaselineSignature = $baselineSignature
    $activeBaselineEvidenceKey = $baselineEvidenceKey

    if ([string]::IsNullOrWhiteSpace($baselineSignature)) {
      Write-Host "Baseline signature is empty. Error change detection may be limited." -ForegroundColor Yellow
    } else {
      Write-Verbose ("Baseline signature: {0}" -f $baselineSignature)
    }

    $pinnedJarNameSet = @{}

    if ($PreIsolateJarNames -and $PreIsolateJarNames.Count -gt 0) {
      $canFastForward = $true
      if (-not [string]::IsNullOrWhiteSpace($PreIsolateBaselineEvidenceKey) -and -not [string]::IsNullOrWhiteSpace($baselineEvidenceKey)) {
        if (-not [string]::Equals($PreIsolateBaselineEvidenceKey, $baselineEvidenceKey, [System.StringComparison]::OrdinalIgnoreCase)) {
          Write-Host "Fast-forward disabled: baseline evidence changed." -ForegroundColor Gray
          Write-Verbose ("Previous baseline evidence: {0}" -f $PreIsolateBaselineEvidenceKey)
          Write-Verbose ("Current baseline evidence: {0}" -f $baselineEvidenceKey)
          $canFastForward = $false
        }
      }
      if (-not $canFastForward) {
        $PreIsolateJarNames = @()
      }

      $preIsolateSet = @{}
      foreach ($name in $PreIsolateJarNames) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $key = $name.ToLowerInvariant()
        if (-not $preIsolateSet.ContainsKey($key)) {
          $preIsolateSet[$key] = $name
        }
      }
      $preList = @($preIsolateSet.Values)
      if ($preList.Count -gt 0) {
        Write-Host ("Fast-forward: quarantining {0} mod(s) from previous isolation run..." -f $preList.Count) -ForegroundColor Cyan
        foreach ($jarName in $preList) {
          if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
          if ($movedJarNameSet.ContainsKey($jarName)) { continue }

          $gamePath = Join-Path -Path $GameModsDir -ChildPath $jarName
          if (-not (Test-Path -LiteralPath $gamePath)) {
            Write-Verbose ("Fast-forward skip missing mod: {0}" -f $jarName)
            continue
          }

          $phase = "fast_forward_move_to_quarantine"
          $ffGameDest = Move-ToQuarantine -SourcePath $gamePath -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
          if ($null -eq $ffGameDest) { continue }

          $ffStorageDest = $null
          if ($useStorage) {
            $storagePath = Join-Path -Path $StorageModsDir -ChildPath $jarName
            if (Test-Path -LiteralPath $storagePath) {
              $ffStorageDest = Move-ToQuarantine -SourcePath $storagePath -DestDir $storageQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
            }
          }

          $movedItems.Add([pscustomobject]@{
              JarName = $jarName
              GameSource = $gamePath
              GameQuarantine = $ffGameDest
              StorageSource = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $jarName } else { $null }
              StorageQuarantine = $ffStorageDest
              IsFastForward = $true
            })
          $movedJarNameSet[$jarName] = $true
          $pinnedJarNameSet[$jarName.ToLowerInvariant()] = $jarName
          Write-Verbose ("Fast-forward moved: {0} -> {1}" -f $jarName, $ffGameDest)
        }
      }
    }

    $pinnedJarNames = @()
    if ($pinnedJarNameSet.Count -gt 0) {
      $pinnedJarNames = @($pinnedJarNameSet.Values)
    }

    $didExponential = $false
    if ($effectiveIsolationStrategy -eq "Exponential") {
      $exponentialCandidates = @($candidateMods | Where-Object { -not $pinnedJarNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
      if ($exponentialCandidates.Count -gt 0) {
        Write-Host ("Exponential isolation enabled. Candidates: {0}" -f $exponentialCandidates.Count) -ForegroundColor Gray
      } else {
        Write-Host "Exponential isolation enabled, but no candidates remain after pinned exclusions." -ForegroundColor Yellow
      }
      if ($exponentialCandidates.Count -gt 0) {
        $exponentialResult = Invoke-ExponentialIsolation -Mods $exponentialCandidates `
          -BaselineSignature $baselineSignature `
          -BaselineEvidenceKey $baselineEvidenceKey `
          -PinnedJarNames $pinnedJarNames
        $didExponential = $true
        $candidateMods = @($exponentialResult.Remaining)
        Write-Host ("Exponential isolation completed. Switching to linear with {0} mod(s) ({1})." -f $candidateMods.Count, $exponentialResult.Reason) -ForegroundColor Gray
      }
    }

    if ($didExponential -and (-not $baselineSucceeded) -and $candidateMods -and $candidateMods.Count -gt 0) {
      # * Exponential/binary probing can quick-isolate additional mods (dependencies/requirers),
      # * which can change the observed error signature. Refresh baseline before the linear phase
      # * to avoid falsely blaming a stable mod as "error_changed" relative to the original baseline.
      Write-Host "Refreshing baseline signature for linear phase." -ForegroundColor Gray

      $linearBaselineAttemptStart = Get-Date
      $phase = "linear_phase_baseline_invoke_launch"
      $linearBaselineOutcomeObj = Invoke-LaunchAttempt -LauncherTitlePattern $LauncherWindowTitlePattern `
        -LauncherPath $LauncherExePath `
        -LauncherArgs $LauncherArguments `
        -AppendAutoLaunch ([bool]$UseAutoLaunch) `
        -LauncherTimeoutSeconds $LauncherWindowTimeoutSeconds `
        -ButtonNames $PlayButtonNames `
        -ClickOffsetX $PlayClickOffsetX `
        -ClickOffsetY $PlayClickOffsetY `
        -EnableEnterFallback $UseEnterFallback `
        -AllowBroadSearch ([bool]$EnableBroadUiSearch) `
        -CrashPatterns $CrashWindowTitlePatterns `
        -FabricPatterns $FabricWindowTitlePatterns `
        -OutcomeTimeoutSeconds $OutcomeTimeoutSeconds `
        -PollSeconds $PollIntervalSeconds `
        -IgnoreHandleIds @()

      $linearBaselineOutcome = $linearBaselineOutcomeObj.Type
      Write-Host ("Linear phase baseline outcome: {0}" -f $linearBaselineOutcome) -ForegroundColor $(if ($linearBaselineOutcome -eq "Timeout") { "Green" } else { "Yellow" })

      if ($linearBaselineOutcome -ne "Timeout") {
        if ($null -ne $linearBaselineOutcomeObj.Window) {
          Write-Host ("Closing outcome window: {0} ({1})" -f $linearBaselineOutcomeObj.Type, $linearBaselineOutcomeObj.Window.Title) -ForegroundColor Gray
          $lastOutcomeHandleId = [long]$linearBaselineOutcomeObj.Window.Handle.ToInt64()
          $phase = "linear_phase_baseline_close_outcome_window"
          Close-OutcomeWindow -Outcome $linearBaselineOutcomeObj `
            -DelaySeconds $CrashCloseDelaySeconds `
            -OffsetX $CrashCloseClickOffsetX `
            -OffsetY $CrashCloseClickOffsetY
          if (Test-WindowStillExists -HandleId $lastOutcomeHandleId) {
            Write-Host ("Warning: outcome window did not close ({0}). It will be detected again on next attempt." -f $linearBaselineOutcomeObj.Type) -ForegroundColor Yellow
            $lastOutcomeHandleId = 0
          }
        }
        $phase = "linear_phase_baseline_wait_game_exit"
        $exited = Wait-ForGameProcessesToExit -Names $GameProcessNames `
          -StartedAfter $linearBaselineAttemptStart `
          -TimeoutSeconds $WaitForGameExitSeconds `
          -PollSeconds $GameExitPollSeconds
        if (-not $exited) {
          Write-Host ("Warning: game processes still running after {0}s. Next file move may fail due to locks." -f $WaitForGameExitSeconds) -ForegroundColor Yellow
        }
      } else {
        # ! If the baseline issue does not reproduce at phase entry, isolation results are unreliable.
        # ! Stop early to prevent moving a random mod to Legacy.
        Write-Host "Warning: baseline issue not reproduced in linear phase. Stopping isolation to avoid false culprit selection." -ForegroundColor Yellow
        $candidateMods = @()
      }

      [void](Wait-ForLauncherWindowInteractive -TitlePattern $LauncherWindowTitlePattern `
          -CrashPatterns $CrashWindowTitlePatterns `
          -FabricPatterns $FabricWindowTitlePatterns `
          -PollSeconds $PollIntervalSeconds)

      if ($candidateMods -and $candidateMods.Count -gt 0 -and $linearBaselineOutcome -ne "Timeout") {
        Start-Sleep -Seconds $LogPostRunDelaySeconds
        $phase = "linear_phase_baseline_read_logs"
        $linearBaselineSnapshot = Get-LogSnapshot -PrimaryLogPath $LogPath `
          -GameModsDir $GameModsDir `
          -SkipGameLogs ([bool]$SkipGameLogs) `
          -LogMaxAgeMinutes $LogMaxAgeMinutes `
          -LogReadRetryCount $LogReadRetryCount `
          -LogReadRetryDelayMs $LogReadRetryDelayMs
        $activeBaselineSignature = Get-ErrorSignature -Lines $linearBaselineSnapshot.Lines `
          -MaxLines $ErrorSignatureLineLimit `
          -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
        $activeBaselineEvidenceKey = Get-ErrorEvidenceKey -Lines $linearBaselineSnapshot.Lines -MaxLines $ErrorSignatureLineLimit
        if ([string]::IsNullOrWhiteSpace($activeBaselineSignature)) {
          Write-Host "Linear phase baseline signature is empty. Error change detection may be limited." -ForegroundColor Yellow
        } else {
          Write-Verbose ("Linear phase baseline signature: {0}" -f $activeBaselineSignature)
        }
      }
    }

    $attemptIndex = 0
    foreach ($mod in $candidateMods) {
      # * Mods can be moved by quick-isolate before their turn in the main loop.
      # * Skip silently to avoid noisy "not moved" warnings and inconsistent attempt behavior.
      if (-not (Test-Path -LiteralPath $mod.FullName)) {
        Write-Verbose ("Skipping already removed or missing mod: {0}" -f $mod.Name)
        continue
      }
      if ($movedJarNameSet.ContainsKey($mod.Name)) {
        Write-Verbose ("Skipping already quarantined mod: {0}" -f $mod.Name)
        continue
      }

      $attemptIndex++
      Write-Host ("Isolation attempt {0}: removing {1}" -f $attemptIndex, $mod.Name) -ForegroundColor Cyan

      $phase = "move_to_quarantine"
      $gameDest = Move-ToQuarantine -SourcePath $mod.FullName -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
      if ($null -eq $gameDest) {
        Write-Verbose ("Skipping not moved (already removed or missing): {0}" -f $mod.FullName)
        continue
      } else {
        Write-Verbose ("Moved: {0} -> {1}" -f $mod.Name, $gameDest)
      }
      $storageDest = $null
      if ($useStorage) {
        $storagePath = Join-Path -Path $StorageModsDir -ChildPath $mod.Name
        if (Test-Path -LiteralPath $storagePath) {
          $storageDest = Move-ToQuarantine -SourcePath $storagePath -DestDir $storageQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
        }
      }

      $movedItems.Add([pscustomobject]@{
          JarName = $mod.Name
          GameSource = $mod.FullName
          GameQuarantine = $gameDest
          StorageSource = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $mod.Name } else { $null }
          StorageQuarantine = $storageDest
        })
      $movedJarNameSet[$mod.Name] = $true

      $ignoreHandles = @()
      if ($lastOutcomeHandleId -ne 0) {
        $ignoreHandles = @($lastOutcomeHandleId)
      }

      $attemptStart = Get-Date
      $phase = "attempt_invoke_launch"
      $outcome = Invoke-LaunchAttempt -LauncherTitlePattern $LauncherWindowTitlePattern `
        -LauncherPath $LauncherExePath `
        -LauncherArgs $LauncherArguments `
        -AppendAutoLaunch ([bool]$UseAutoLaunch) `
        -LauncherTimeoutSeconds $LauncherWindowTimeoutSeconds `
        -ButtonNames $PlayButtonNames `
        -ClickOffsetX $PlayClickOffsetX `
        -ClickOffsetY $PlayClickOffsetY `
        -EnableEnterFallback $UseEnterFallback `
        -AllowBroadSearch ([bool]$EnableBroadUiSearch) `
        -CrashPatterns $CrashWindowTitlePatterns `
        -FabricPatterns $FabricWindowTitlePatterns `
        -OutcomeTimeoutSeconds $OutcomeTimeoutSeconds `
        -PollSeconds $PollIntervalSeconds `
        -IgnoreHandleIds $ignoreHandles

      Write-Host ("Outcome: {0}" -f $outcome.Type) -ForegroundColor $(if ($outcome.Type -eq "Timeout") { "Green" } else { "Yellow" })
      if ($outcome.Type -ne "Timeout" -and $null -ne $outcome.Window) {
        Write-Host ("Closing outcome window: {0} ({1})" -f $outcome.Type, $outcome.Window.Title) -ForegroundColor Gray
        $lastOutcomeHandleId = [long]$outcome.Window.Handle.ToInt64()
        $phase = "attempt_close_outcome_window"
        Close-OutcomeWindow -Outcome $outcome `
          -DelaySeconds $CrashCloseDelaySeconds `
          -OffsetX $CrashCloseClickOffsetX `
          -OffsetY $CrashCloseClickOffsetY

        # * Some launchers show both a generic crash dialog and Fabric's incompatibility dialog.
        # * Close Fabric dialog too to keep automation continuous.
        $extraFabricWindow = Select-WindowByTitlePatterns -Patterns $FabricWindowTitlePatterns
        if ($null -ne $extraFabricWindow) {
          Write-Host ("Closing extra Fabric Loader dialog: {0}" -f $extraFabricWindow.Title) -ForegroundColor Gray
          Close-OutcomeWindow -Outcome ([pscustomobject]@{ Type = "FabricDialog"; Window = $extraFabricWindow }) `
            -DelaySeconds 0 `
            -OffsetX -1 `
            -OffsetY -1
        }

        # * Verify the window actually closed. If not, don't ignore it in future attempts.
        if (Test-WindowStillExists -HandleId $lastOutcomeHandleId) {
          Write-Host ("Warning: outcome window did not close ({0}). It will be detected again on next attempt." -f $outcome.Type) -ForegroundColor Yellow
          $lastOutcomeHandleId = 0
        }
        $phase = "attempt_wait_game_exit"
        $exited = Wait-ForGameProcessesToExit -Names $GameProcessNames `
          -StartedAfter $attemptStart `
          -TimeoutSeconds $WaitForGameExitSeconds `
          -PollSeconds $GameExitPollSeconds
        if (-not $exited) {
          Write-Host ("Warning: game processes still running after {0}s. Next file move may fail due to locks." -f $WaitForGameExitSeconds) -ForegroundColor Yellow
        }
      }

      [void](Wait-ForLauncherWindowInteractive -TitlePattern $LauncherWindowTitlePattern `
          -CrashPatterns $CrashWindowTitlePatterns `
          -FabricPatterns $FabricWindowTitlePatterns `
          -PollSeconds $PollIntervalSeconds)

      if ($outcome.Type -eq "Timeout") {
        $culpritJarNames = @($mod.Name)
        $stopReason = "success"
        break
      }

      Start-Sleep -Seconds $LogPostRunDelaySeconds
      $phase = "attempt_read_logs"
      $snapshot = Get-LogSnapshot -PrimaryLogPath $LogPath `
        -GameModsDir $GameModsDir `
        -SkipGameLogs ([bool]$SkipGameLogs) `
        -LogMaxAgeMinutes $LogMaxAgeMinutes `
        -LogReadRetryCount $LogReadRetryCount `
        -LogReadRetryDelayMs $LogReadRetryDelayMs

      if ($mcVersionForLegacy -eq "unknown") {
        $mcVersionForLegacy = Get-MinecraftVersionFromLog -Lines $snapshot.Lines
      }

      # * Fabric signals (from window or from logs). This makes behavior visible in console output.
      $fabricIdsFromLogs = Get-FabricRequiringModIds -Lines $snapshot.Lines
      $fabricMissingIdsFromLogs = Get-FabricMissingDependencyIds -Lines $snapshot.Lines
      $fabricWindowNow = Select-WindowByTitlePatterns -Patterns $FabricWindowTitlePatterns
      if (($null -ne $fabricWindowNow) -or ($fabricIdsFromLogs -and $fabricIdsFromLogs.Count -gt 0) -or ($fabricMissingIdsFromLogs -and $fabricMissingIdsFromLogs.Count -gt 0)) {
        $reqText = if ($fabricIdsFromLogs -and $fabricIdsFromLogs.Count -gt 0) { $fabricIdsFromLogs -join ", " } else { "" }
        $missText = if ($fabricMissingIdsFromLogs -and $fabricMissingIdsFromLogs.Count -gt 0) { $fabricMissingIdsFromLogs -join ", " } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($reqText) -or -not [string]::IsNullOrWhiteSpace($missText)) {
          Write-Host ("Fabric detected. Requiring mods: {0}; Missing deps: {1}" -f $reqText, $missText) -ForegroundColor Yellow
        } else {
          Write-Host "Fabric window detected." -ForegroundColor Yellow
        }
      }

      if ($outcome.Type -eq "FabricDialog") {
        # * Fabric dependency dialog:
        # * - Prefer isolating the requiring mod(s) (not the missing dependency).
        # * - If the removed jar is the missing dependency, restore it to avoid falsely blaming it.
        $newModIds = $fabricIdsFromLogs
        $missingDepIds = $fabricMissingIdsFromLogs
        $newModIdsArr = @($newModIds)
        $missingDepIdsArr = @($missingDepIds)

        $removedItem = $null
        for ($i = $movedItems.Count - 1; $i -ge 0; $i--) {
          if ($movedItems[$i].JarName -eq $mod.Name) { $removedItem = $movedItems[$i]; break }
        }
        $removedJarProvides = @()
        if ($null -ne $removedItem -and $null -ne $removedItem.GameQuarantine -and (Test-Path -LiteralPath $removedItem.GameQuarantine)) {
          $removedJarProvides = Get-FabricModIdsFromJar -JarPath $removedItem.GameQuarantine
        }
        $removedJarProvidesArr = @($removedJarProvides)

        $isLikelyRemovedDep = $false
        if ($missingDepIdsArr.Count -gt 0) {
          if ($removedJarProvidesArr.Count -gt 0) {
            $isLikelyRemovedDep = Test-AnyIdOverlap -IdsA $removedJarProvidesArr -IdsB $missingDepIdsArr
          }
          if (-not $isLikelyRemovedDep) {
            $isLikelyRemovedDep = Test-JarNameMatchesAnyId -JarName $mod.Name -Ids $missingDepIdsArr
          }
        }

        if ($isLikelyRemovedDep) {
          Write-Host ("Fabric missing dependency '{0}' appears caused by removing '{1}'. Restoring dependency and isolating requiring mod(s)." -f ($missingDepIdsArr -join ", "), $mod.Name) -ForegroundColor Cyan

          if ($null -ne $removedItem -and $null -ne $removedItem.GameQuarantine -and (Test-Path -LiteralPath $removedItem.GameQuarantine)) {
            [void](Restore-FromQuarantine -SourcePath $removedItem.GameQuarantine -DestDir $GameModsDir -IsDryRun $false -AllowOverwrite $true)
            $removedItem.GameQuarantine = $null
          }
          if ($useStorage -and $null -ne $removedItem -and $null -ne $removedItem.StorageQuarantine -and (Test-Path -LiteralPath $removedItem.StorageQuarantine)) {
            [void](Restore-FromQuarantine -SourcePath $removedItem.StorageQuarantine -DestDir $StorageModsDir -IsDryRun $false -AllowOverwrite $true)
            $removedItem.StorageQuarantine = $null
          }
        }

        if ($newModIdsArr.Count -gt 0) {
          Write-Host ("Fabric dialog detected. Quick-isolating requiring mods: {0}" -f ($newModIdsArr -join ", ")) -ForegroundColor Cyan
          $culpritJars = Find-ModJarsByIdsBestEffort -ModsDir $GameModsDir -ModIds $newModIdsArr
          if ($culpritJars -and $culpritJars.Count -gt 0) {
            foreach ($cj in $culpritJars) {
              if ($movedJarNameSet.ContainsKey($cj.Name)) { continue }
              Write-Host ("Quick-isolating: {0}" -f $cj.Name) -ForegroundColor Cyan
              $phase = "quick_isolate_move"
              $qDest = Move-ToQuarantine -SourcePath $cj.FullName -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
              if ($null -ne $qDest) {
                $movedItems.Add([pscustomobject]@{
                    JarName = $cj.Name
                    GameSource = $cj.FullName
                    GameQuarantine = $qDest
                    StorageSource = $null
                    StorageQuarantine = $null
                  })
                $movedJarNameSet[$cj.Name] = $true
              }
            }
          } else {
            Write-Host ("Warning: could not resolve requiring mod jar(s) for ids: {0}. Continuing isolation." -f ($newModIdsArr -join ", ")) -ForegroundColor Yellow
          }
          Write-Host "Continuing isolation after Fabric quick-isolate..." -ForegroundColor Cyan
          continue
        }

        if ($isLikelyRemovedDep) {
          # * We restored the dependency; proceed with next candidate.
          Write-Host "Continuing isolation after dependency restore..." -ForegroundColor Cyan
          continue
        }
      }

      $signature = Get-ErrorSignature -Lines $snapshot.Lines `
        -MaxLines $ErrorSignatureLineLimit `
        -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
      $evidenceKey = Get-ErrorEvidenceKey -Lines $snapshot.Lines -MaxLines $ErrorSignatureLineLimit

      Write-Verbose ("Signature: {0}" -f $signature)
      if (Test-SignatureChanged -Baseline $activeBaselineSignature -Current $signature `
          -BaselineEvidenceKey $activeBaselineEvidenceKey -CurrentEvidenceKey $evidenceKey `
          -IgnoreModsWhenEvidencePresent ([bool]$IgnoreModListForSignatureChange)) {
        # * Confirm signature change to avoid log-flush noise.
        Start-Sleep -Milliseconds 750
        $confirmSnapshot = Get-LogSnapshot -PrimaryLogPath $LogPath `
          -GameModsDir $GameModsDir `
          -SkipGameLogs ([bool]$SkipGameLogs) `
          -LogMaxAgeMinutes $LogMaxAgeMinutes `
          -LogReadRetryCount $LogReadRetryCount `
          -LogReadRetryDelayMs $LogReadRetryDelayMs
        $confirmSignature = Get-ErrorSignature -Lines $confirmSnapshot.Lines `
          -MaxLines $ErrorSignatureLineLimit `
          -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
        $confirmEvidenceKey = Get-ErrorEvidenceKey -Lines $confirmSnapshot.Lines -MaxLines $ErrorSignatureLineLimit
        if (-not (Test-SignatureChanged -Baseline $activeBaselineSignature -Current $confirmSignature `
              -BaselineEvidenceKey $activeBaselineEvidenceKey -CurrentEvidenceKey $confirmEvidenceKey `
              -IgnoreModsWhenEvidencePresent ([bool]$IgnoreModListForSignatureChange))) {
          Write-Verbose "Transient signature change detected; continuing."
          continue
        }

        # * Try to identify culprit mods from Fabric dependency errors.
        $newModIds = Get-FabricRequiringModIds -Lines $snapshot.Lines
        $missingDepIds = Get-FabricMissingDependencyIds -Lines $snapshot.Lines
        $newModIdsArr = @($newModIds)
        $missingDepIdsArr = @($missingDepIds)

        # * Special-case: if the "error change" is a missing dependency introduced by removing a library,
        # * then the removed jar is NOT the culprit. Restore it and instead isolate the requiring mod(s).
        $removedJarProvides = @()
        $removedItem = $null
        for ($i = $movedItems.Count - 1; $i -ge 0; $i--) {
          if ($movedItems[$i].JarName -eq $mod.Name) { $removedItem = $movedItems[$i]; break }
        }
        if ($null -ne $removedItem -and $null -ne $removedItem.GameQuarantine -and (Test-Path -LiteralPath $removedItem.GameQuarantine)) {
          $removedJarProvides = Get-FabricModIdsFromJar -JarPath $removedItem.GameQuarantine
        }
        $removedJarProvidesArr = @($removedJarProvides)

        $isLikelyRemovedDep = $false
        if ($newModIdsArr.Count -gt 0 -and $missingDepIdsArr.Count -gt 0) {
          if ($removedJarProvidesArr.Count -gt 0) {
            $isLikelyRemovedDep = Test-AnyIdOverlap -IdsA $removedJarProvidesArr -IdsB $missingDepIdsArr
          }
          if (-not $isLikelyRemovedDep) {
            $isLikelyRemovedDep = Test-JarNameMatchesAnyId -JarName $mod.Name -Ids $missingDepIdsArr
          }
        }

        if ($isLikelyRemovedDep) {
          Write-Host ("Detected missing dependency caused by removed library '{0}'. Restoring it and isolating requiring mod(s)." -f $mod.Name) -ForegroundColor Cyan

            # * Restore removed dependency jar back to active mods (and storage if applicable).
            if ($null -ne $removedItem -and $null -ne $removedItem.GameQuarantine -and (Test-Path -LiteralPath $removedItem.GameQuarantine)) {
              [void](Restore-FromQuarantine -SourcePath $removedItem.GameQuarantine -DestDir $GameModsDir -IsDryRun $false -AllowOverwrite $true)
              $removedItem.GameQuarantine = $null
            }
            if ($useStorage -and $null -ne $removedItem -and $null -ne $removedItem.StorageQuarantine -and (Test-Path -LiteralPath $removedItem.StorageQuarantine)) {
              [void](Restore-FromQuarantine -SourcePath $removedItem.StorageQuarantine -DestDir $StorageModsDir -IsDryRun $false -AllowOverwrite $true)
              $removedItem.StorageQuarantine = $null
            }

            # * Isolate the requiring mods instead.
            $requiringJars = Find-ModJarsByIdsBestEffort -ModsDir $GameModsDir -ModIds $newModIdsArr
            if ($requiringJars -and $requiringJars.Count -gt 0) {
              $culpritJarNames = @()
              foreach ($rj in $requiringJars) {
                Write-Host ("Isolating requiring mod: {0}" -f $rj.Name) -ForegroundColor Cyan
                $rDest = Move-ToQuarantine -SourcePath $rj.FullName -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
                $rStorageDest = $null
                if ($useStorage) {
                  $rStoragePath = Join-Path -Path $StorageModsDir -ChildPath $rj.Name
                  if (Test-Path -LiteralPath $rStoragePath) {
                    $rStorageDest = Move-ToQuarantine -SourcePath $rStoragePath -DestDir $storageQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
                  }
                }
                $movedItems.Add([pscustomobject]@{
                    JarName = $rj.Name
                    GameSource = $rj.FullName
                    GameQuarantine = $rDest
                    StorageSource = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $rj.Name } else { $null }
                    StorageQuarantine = $rStorageDest
                  })
                $movedJarNameSet[$rj.Name] = $true
                $culpritJarNames += @($rj.Name)
              }
              $stopReason = "fabric_missing_dependency"
              break
            }

            # ! If we cannot map requiring mod IDs to jar files, do NOT blame the removed library.
            # ! The safest behavior is to continue isolation with the library restored.
            Write-Host ("Warning: could not resolve requiring mod jar(s) for ids: {0}. Continuing isolation." -f ($newModIdsArr -join ", ")) -ForegroundColor Yellow
            continue
        }

        $movedExtra = $false
        if ($newModIds -and $newModIds.Count -gt 0) {
          Write-Host ("Fabric dependency error detected. Mods requiring missing deps: {0}" -f ($newModIds -join ", ")) -ForegroundColor Yellow
          $culpritJars = Find-ModJarsByIdsBestEffort -ModsDir $GameModsDir -ModIds $newModIds
          if ($culpritJars -and $culpritJars.Count -gt 0) {
            foreach ($cj in $culpritJars) {
              # * Skip if already moved.
              if ($movedJarNameSet.ContainsKey($cj.Name)) { continue }

              Write-Host ("Quick-isolating: {0}" -f $cj.Name) -ForegroundColor Cyan
              $phase = "quick_isolate_move"
              $qDest = Move-ToQuarantine -SourcePath $cj.FullName -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
              if ($null -ne $qDest) {
                $movedItems.Add([pscustomobject]@{
                    JarName = $cj.Name
                    GameSource = $cj.FullName
                    GameQuarantine = $qDest
                    StorageSource = $null
                    StorageQuarantine = $null
                  })
                $movedJarNameSet[$cj.Name] = $true
                $movedExtra = $true
              }
            }
          }
        }
        if ($movedExtra) {
          # * Continue isolation with newly identified mods removed.
          Write-Host "Continuing isolation after quick-isolate..." -ForegroundColor Cyan
          continue
        }
        $culpritJarNames = @($mod.Name)
        $stopReason = "error_changed"
        break
      }
    }
  }
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
        if ($null -ne $item.GameQuarantine) {
          $restoreGame = Restore-FromQuarantine -SourcePath $item.GameQuarantine `
            -DestDir $GameModsDir `
            -IsDryRun $false `
            -AllowOverwrite ([bool]$ForceRestore)
          if ($restoreGame) {
            $restoreCount++
            Write-Verbose ("Restored game mod: {0}" -f $restoreGame)
          }
        }
        if ($useStorage -and $null -ne $item.StorageQuarantine) {
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

  if (-not $DryRun -and (-not $hadError) -and $culpritJarNames -and $culpritJarNames.Count -gt 0) {
    # * Prefer moving culprits into Storage legacy (source of truth).
    # * Keep a game-legacy copy only when explicitly requested (or when storage is unavailable).
    $storageLegacyVersionDir = $null
    if ($useStorage) {
      $storageLegacyRoot = Join-Path -Path $StorageModsDir -ChildPath $StorageLegacyFolderName
      $storageLegacyVersionDir = Join-Path -Path $storageLegacyRoot -ChildPath $mcVersionForLegacy
      New-DirectoryIfMissing -DirPath $storageLegacyVersionDir
    }

    $keepGameLegacyEffective = [bool]$KeepCulpritInGameLegacy
    if (-not $useStorage -and (-not $keepGameLegacyEffective)) {
      Write-Host "Warning: storage is disabled/unavailable; keeping culprit in game legacy to avoid data loss." -ForegroundColor Yellow
      $keepGameLegacyEffective = $true
    }

    $gameLegacyVersionDir = $null
    if ($keepGameLegacyEffective) {
      $gameLegacyRoot = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
      $gameLegacyVersionDir = Join-Path -Path $gameLegacyRoot -ChildPath $mcVersionForLegacy
      New-DirectoryIfMissing -DirPath $gameLegacyVersionDir
    }

    foreach ($culpritName in $culpritJarNames) {
      if ([string]::IsNullOrWhiteSpace($culpritName)) { continue }

      $movedStorageLegacy = $false
      $storageOk = $false
      $culpritStorageLegacyPath = $null
      $culpritGameLegacyPath = $null

      # * Move to storage legacy first when available (prefer the quarantined storage copy).
      foreach ($item in $movedItems) {
        if ($item.JarName -ne $culpritName) { continue }

        if ($useStorage -and (-not $movedStorageLegacy) -and $null -ne $item.StorageQuarantine -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
          $destPath = Join-Path -Path $storageLegacyVersionDir -ChildPath $culpritName
          Move-Item -LiteralPath $item.StorageQuarantine -Destination $destPath -Force -ErrorAction Stop
          Write-Host ("Moved culprit to storage legacy: {0}" -f $destPath) -ForegroundColor Green
          $culpritStorageLegacyPath = $destPath
          $movedStorageLegacy = $true
        }
      }

      if ($useStorage -and (-not $movedStorageLegacy)) {
        $storagePath = Join-Path -Path $StorageModsDir -ChildPath $culpritName
        if (Test-Path -LiteralPath $storagePath) {
          $destPath = Join-Path -Path $storageLegacyVersionDir -ChildPath $culpritName
          Move-Item -LiteralPath $storagePath -Destination $destPath -Force -ErrorAction Stop
          Write-Host ("Moved culprit to storage legacy: {0}" -f $destPath) -ForegroundColor Green
          $culpritStorageLegacyPath = $destPath
          $movedStorageLegacy = $true
        } else {
          Write-Host ("Warning: culprit jar not found in storage for legacy move: {0}" -f $culpritName) -ForegroundColor Yellow
        }
      }

      $storageOk = (-not $useStorage) -or $movedStorageLegacy

      # * Handle game side.
      if ($keepGameLegacyEffective) {
        $movedGameLegacy = $false
        foreach ($item in $movedItems) {
          if ($item.JarName -ne $culpritName) { continue }
          if (-not $movedGameLegacy -and $null -ne $item.GameQuarantine -and (Test-Path -LiteralPath $item.GameQuarantine)) {
            $destPath = Join-Path -Path $gameLegacyVersionDir -ChildPath $culpritName
            Move-Item -LiteralPath $item.GameQuarantine -Destination $destPath -Force -ErrorAction Stop
            Write-Host ("Moved culprit to game legacy: {0}" -f $destPath) -ForegroundColor Green
            $culpritGameLegacyPath = $destPath
            $movedGameLegacy = $true
          }
        }
        if (-not $movedGameLegacy) {
          $gamePath = Join-Path -Path $GameModsDir -ChildPath $culpritName
          if (Test-Path -LiteralPath $gamePath) {
            $destPath = Join-Path -Path $gameLegacyVersionDir -ChildPath $culpritName
            Move-Item -LiteralPath $gamePath -Destination $destPath -Force -ErrorAction Stop
            Write-Host ("Moved culprit to game legacy: {0}" -f $destPath) -ForegroundColor Green
            $culpritGameLegacyPath = $destPath
            $movedGameLegacy = $true
          }
        }
        if (-not $movedGameLegacy -and (-not $storageOk)) {
          Write-Host ("Warning: culprit jar was not moved to any legacy location: {0}" -f $culpritName) -ForegroundColor Yellow
        }
      } else {
        # * Do not keep game legacy copy unless requested. Remove only after storage copy is secured.
        if (-not $storageOk) {
          Write-Host ("Warning: storage legacy move did not happen; keeping culprit in quarantine: {0}" -f $culpritName) -ForegroundColor Yellow
          continue
        }

        $removedGameSide = $false
        foreach ($item in $movedItems) {
          if ($item.JarName -ne $culpritName) { continue }
          if ($null -ne $item.GameQuarantine -and (Test-Path -LiteralPath $item.GameQuarantine)) {
            Remove-Item -LiteralPath $item.GameQuarantine -Force -ErrorAction Stop
            Write-Verbose ("Removed culprit from game quarantine: {0}" -f $culpritName)
            $removedGameSide = $true
            break
          }
        }
        if (-not $removedGameSide) {
          $gamePath = Join-Path -Path $GameModsDir -ChildPath $culpritName
          if (Test-Path -LiteralPath $gamePath) {
            Remove-Item -LiteralPath $gamePath -Force -ErrorAction Stop
            Write-Verbose ("Removed culprit from game mods: {0}" -f $culpritName)
            $removedGameSide = $true
          }
        }
        if (-not $removedGameSide) {
          Write-Verbose ("Culprit not present on game side (already removed): {0}" -f $culpritName)
        }
      }

      $culpritMoves.Add([pscustomobject]@{
          JarName = $culpritName
          GameModsDir = $GameModsDir
          StorageModsDir = if ($useStorage) { $StorageModsDir } else { "" }
          StorageLegacyPath = $culpritStorageLegacyPath
          GameLegacyPath = $culpritGameLegacyPath
          Minecraft = $mcVersionForLegacy
          KeepCulpritInGameLegacy = [bool]$keepGameLegacyEffective
        })
    }
  }
}

if ($baselineSucceeded) {
  Write-Host "Baseline launch succeeded. No isolation needed." -ForegroundColor Green
  $exitCode = 0
}

if ($culpritJarNames -and $culpritJarNames.Count -gt 0) {
  Write-Host ("Culprit candidate(s): {0}" -f (($culpritJarNames | Sort-Object -Unique) -join ", ")) -ForegroundColor Green
  Write-Host ("Stop reason: {0}" -f $stopReason) -ForegroundColor Cyan
  $exitCode = 0
} elseif (-not $hadError) {
  Write-Host "No error change or successful launch detected." -ForegroundColor Yellow
  $exitCode = 2
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

  Write-Output ([pscustomobject]@{
      Type = "IsolationResult"
      RunId = $runId
      GameModsDir = $GameModsDir
      StorageModsDir = if ($useStorage) { $StorageModsDir } else { "" }
      Minecraft = $mcVersionForLegacy
      BaselineOutcome = $baselineOutcome
      BaselineSignature = $baselineSignature
      BaselineEvidenceKey = $baselineEvidenceKey
      StopReason = $stopReason
      CulpritJarNames = @($culpritJarNames | Sort-Object -Unique)
      CulpritMoves = @($culpritMoves.ToArray())
      FastForwardJarNames = @($fastForward.ToArray())
      PreIsolateJarNames = @($PreIsolateJarNames)
      ExitCode = $exitCode
    })
}

exit $exitCode

