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
If set, appends --launch to enable auto-start.

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

.PARAMETER PrintCursorOffset
If set, prints current mouse offsets relative to the launcher window and uses them for click.

.PARAMETER DeleteFromGameMods
If set, passes -DeleteFromGameMods to compatibility checker.

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
Fabric error dialog title fragments.

.PARAMETER CheckScriptPath
Path to compatibility script.

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

  [Parameter(Mandatory = $false)]
  [int]$PlayClickOffsetY = -1,

  # * If true, sends ENTER when play element is not found.
  [Parameter(Mandatory = $false)]
  [bool]$UseEnterFallback = $true,

  # * If set, prints current mouse offsets relative to the launcher window and uses them for click.
  [Parameter(Mandatory = $false)]
  [switch]$PrintCursorOffset,

  # * If set, passes -DeleteFromGameMods to compatibility checker.
  [Parameter(Mandatory = $false)]
  [switch]$DeleteFromGameMods,

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

  # * Fabric error dialog title fragments.
  [Parameter(Mandatory = $false)]
  [string[]]$FabricWindowTitlePatterns = @("Fabric Loader"),

  # * Path to compatibility script.
  [Parameter(Mandatory = $false)]
  [string]$CheckScriptPath = "",

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

if ($Help) {
  Get-Help -Full -Name $PSCommandPath
  return
}

if ([string]::IsNullOrWhiteSpace($CheckScriptPath)) {
  $CheckScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Check-Mod-Compatibility.ps1"
}

if (-not (Test-Path -LiteralPath $CheckScriptPath)) {
  throw ("Check script not found: {0}" -f $CheckScriptPath)
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName System.Windows.Forms

if (-not ("Win32" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Win32 {
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

function Get-CursorOffsetRelativeToWindow {
  param(
    [Parameter(Mandatory = $true)]
    [IntPtr]$Handle
  )

  $rect = New-Object Win32+RECT
  if (-not [Win32]::GetWindowRect($Handle, [ref]$rect)) {
    throw "Failed to read window rectangle."
  }
  $point = New-Object Win32+POINT
  if (-not [Win32]::GetCursorPos([ref]$point)) {
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
    [int]$OffsetY,
    [Parameter(Mandatory = $true)]
    [bool]$IsDryRun
  )

  $rect = New-Object Win32+RECT
  if (-not [Win32]::GetWindowRect($Handle, [ref]$rect)) {
    throw "Failed to read window rectangle."
  }
  $targetX = $rect.Left + $OffsetX
  $targetY = $rect.Top + $OffsetY
  if ($IsDryRun) {
    Write-Host ("DRYRUN would click at: {0},{1}" -f $targetX, $targetY)
    return
  }
  [void][Win32]::SetCursorPos($targetX, $targetY)
  [Win32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  [Win32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function Get-WindowList {
  $windows = New-Object System.Collections.Generic.List[object]

  $callback = [Win32+EnumWindowsProc]{
    param([IntPtr]$hWnd, [IntPtr]$lParam)

    if (-not [Win32]::IsWindowVisible($hWnd)) { return $true }
    $length = [Win32]::GetWindowTextLength($hWnd)
    if ($length -le 0) { return $true }

    $builder = New-Object System.Text.StringBuilder ($length + 1)
    [void][Win32]::GetWindowText($hWnd, $builder, $builder.Capacity)
    $title = $builder.ToString()
    if ([string]::IsNullOrWhiteSpace($title)) { return $true }

    $processId = 0
    [void][Win32]::GetWindowThreadProcessId($hWnd, [ref]$processId)
    $windows.Add([pscustomobject]@{
        Handle = $hWnd
        Title = $title
        ProcessId = $processId
      })
    return $true
  }

  [void][Win32]::EnumWindows($callback, [IntPtr]::Zero)
  return $windows
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
    Write-Host "Launcher window not found. Waiting for it to appear..."
    $waited = Wait-ForLauncherWindow -TitlePattern $TitlePattern -TimeoutSeconds $TimeoutSeconds
    if ($null -eq $waited) {
      Write-Host ("Launcher window not found after {0}s." -f $TimeoutSeconds)
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

  Write-Host ("Starting launcher: {0}" -f $ExePath)
  if (-not $DryRun) {
    if ($startArgs.Count -gt 0) {
      Start-Process -FilePath $ExePath -ArgumentList $startArgs | Out-Null
    } else {
      Start-Process -FilePath $ExePath | Out-Null
    }
  } else {
    if ($startArgs.Count -gt 0) {
      Write-Host ("DRYRUN would start: {0} {1}" -f $ExePath, ($startArgs -join " "))
    } else {
      Write-Host ("DRYRUN would start: {0}" -f $ExePath)
    }
  }

  $started = Wait-ForLauncherWindow -TitlePattern $TitlePattern -TimeoutSeconds $TimeoutSeconds
  if ($null -eq $started) {
    throw ("Launcher window not found after {0}s." -f $TimeoutSeconds)
  }
  return $started
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
    [bool]$EnableEnterFallback
  )

  [void][Win32]::SetForegroundWindow($LauncherHandle)
  Start-Sleep -Milliseconds 150
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
        if (-not $DryRun) {
          $invokePattern.Invoke()
        } else {
          Write-Host ("DRYRUN would click Play button: {0}" -f $buttonName)
        }
        return
      }
    }
  }

  # * Fallback: any control with matching Name.
  $allElements = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($element in $allElements) {
    $name = $element.Current.Name
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    foreach ($buttonName in $ButtonNames) {
      if (Test-TitleMatch -Title $name -Pattern $buttonName) {
        $invokePattern = $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern) -as [System.Windows.Automation.InvokePattern]
        if ($null -ne $invokePattern) {
          if (-not $DryRun) {
            $invokePattern.Invoke()
          } else {
            Write-Host ("DRYRUN would click Play element: {0}" -f $name)
          }
          return
        }
        $legacyPattern = $element.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern) -as [System.Windows.Automation.LegacyIAccessiblePattern]
        if ($null -ne $legacyPattern) {
          if (-not $DryRun) {
            $legacyPattern.DoDefaultAction()
          } else {
            Write-Host ("DRYRUN would activate element: {0}" -f $name)
          }
          return
        }
      }
    }
  }

  if ($ClickOffsetX -ge 0 -and $ClickOffsetY -ge 0) {
    $rect = New-Object Win32+RECT
    if (-not [Win32]::GetWindowRect($LauncherHandle, [ref]$rect)) {
      throw "Failed to read launcher window rectangle."
    }
    $targetX = $rect.Left + $ClickOffsetX
    $targetY = $rect.Top + $ClickOffsetY
    if (-not $DryRun) {
      [void][Win32]::SetCursorPos($targetX, $targetY)
      [Win32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
      [Win32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    } else {
      Write-Host ("DRYRUN would click at: {0},{1}" -f $targetX, $targetY)
    }
    return
  }

  if ($EnableEnterFallback) {
    [void][Win32]::SetForegroundWindow($LauncherHandle)
    Start-Sleep -Milliseconds 150
    if (-not $DryRun) {
      [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    } else {
      Write-Host "DRYRUN would send ENTER to launcher window."
    }
    return
  }

  throw ("Play element not found. Set -PlayClickOffsetX/Y or enable Enter fallback. Names tried: {0}" -f ($ButtonNames -join ", "))
}

function Invoke-WindowClose {
  param(
    [Parameter(Mandatory = $true)]
    [IntPtr]$Handle
  )

  $wmClose = 0x0010
  [void][Win32]::SendMessage($Handle, $wmClose, [IntPtr]::Zero, [IntPtr]::Zero)
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
    [long[]]$IgnoreCrashHandleIds = @()
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $fabricDetected = $false

  while ((Get-Date) -lt $deadline) {
    $crashWindow = Select-WindowByTitlePatterns -Patterns $CrashPatterns -ExcludeHandleIds $IgnoreCrashHandleIds
    if ($null -ne $crashWindow) {
      return [pscustomobject]@{ Type = "CrashDialog"; Window = $crashWindow; FabricDetected = $fabricDetected }
    }

    $fabricWindow = Select-WindowByTitlePatterns -Patterns $FabricPatterns
    if ($null -ne $fabricWindow) {
      $fabricDetected = $true
    }

    Start-Sleep -Seconds $PollSeconds
  }

  return [pscustomobject]@{ Type = "Timeout"; Window = $null; FabricDetected = $fabricDetected }
}

Write-Host ("Launcher title pattern: {0}" -f $LauncherWindowTitlePattern)
Write-Host "Attempt limit: unlimited"
$launcherWindow = $null
$lastCrashDialogHandleId = 0

if ($PrintCursorOffset) {
  $launcherWindow = Start-LauncherIfNeeded -TitlePattern $LauncherWindowTitlePattern -ExePath $LauncherExePath -ExeArguments $LauncherArguments -AppendAutoLaunch ([bool]$UseAutoLaunch) -TimeoutSeconds $LauncherWindowTimeoutSeconds
  while ($null -eq $launcherWindow) {
    Write-Host ("Launcher window not found. Waiting {0}s..." -f $PollIntervalSeconds)
    Start-Sleep -Seconds $PollIntervalSeconds
    $launcherWindow = Start-LauncherIfNeeded -TitlePattern $LauncherWindowTitlePattern -ExePath $LauncherExePath -ExeArguments $LauncherArguments -AppendAutoLaunch ([bool]$UseAutoLaunch) -TimeoutSeconds $LauncherWindowTimeoutSeconds
  }
  $rect = New-Object Win32+RECT
  if (-not [Win32]::GetWindowRect($launcherWindow.Handle, [ref]$rect)) {
    throw "Failed to read launcher window rectangle."
  }
  $point = New-Object Win32+POINT
  if (-not [Win32]::GetCursorPos([ref]$point)) {
    throw "Failed to read cursor position."
  }
  $offsetX = $point.X - $rect.Left
  $offsetY = $point.Y - $rect.Top
  Write-Host ("Cursor offsets: X={0}, Y={1}" -f $offsetX, $offsetY)

  if ($PlayClickOffsetX -lt 0 -or $PlayClickOffsetY -lt 0) {
    $PlayClickOffsetX = $offsetX
    $PlayClickOffsetY = $offsetY
    Write-Host ("Using cursor offsets for click: X={0}, Y={1}" -f $PlayClickOffsetX, $PlayClickOffsetY)
  }
}

$attempt = 0
while ($true) {
  $attempt++
  Write-Host ("Attempt {0}" -f $attempt)

  $launcherWindow = Start-LauncherIfNeeded -TitlePattern $LauncherWindowTitlePattern -ExePath $LauncherExePath -ExeArguments $LauncherArguments -AppendAutoLaunch ([bool]$UseAutoLaunch) -TimeoutSeconds $LauncherWindowTimeoutSeconds
  if ($null -eq $launcherWindow) {
    $answer = Read-Host "Лаунчер не найден. Продолжить попытки? (y/n)"
    if ($answer -notmatch "^(y|yes|д|да)$") {
      Write-Host "Stopping by user choice."
      exit 0
    }
    Write-Host ("Retrying in {0}s." -f $PollIntervalSeconds)
    Start-Sleep -Seconds $PollIntervalSeconds
    continue
  }
  Invoke-LauncherPlay -LauncherHandle $launcherWindow.Handle -ButtonNames $PlayButtonNames -ClickOffsetX $PlayClickOffsetX -ClickOffsetY $PlayClickOffsetY -EnableEnterFallback $UseEnterFallback

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
    -IgnoreCrashHandleIds $ignoreCrashIds

  if ($outcome.Type -eq "CrashDialog") {
    Write-Host "Outcome: crash dialog detected. Running compatibility cleanup."

    if (-not $DryRun) {
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
      if ($PSBoundParameters.ContainsKey("Verbose")) {
        $hasVerboseArg = $false
        foreach ($arg in $compatArgs) {
          if ($arg -ieq "-Verbose") {
            $hasVerboseArg = $true
            break
          }
        }
        if (-not $hasVerboseArg) {
          $compatArgs += @("-Verbose")
        }
      }
      & $CheckScriptPath @compatArgs
    } else {
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
      if ($PSBoundParameters.ContainsKey("Verbose")) {
        $hasVerboseArg = $false
        foreach ($arg in $compatArgs) {
          if ($arg -ieq "-Verbose") {
            $hasVerboseArg = $true
            break
          }
        }
        if (-not $hasVerboseArg) {
          $compatArgs += @("-Verbose")
        }
      }
      if ($compatArgs.Count -gt 0) {
        Write-Host ("DRYRUN would run: {0} {1}" -f $CheckScriptPath, ($compatArgs -join " "))
      } else {
        Write-Host ("DRYRUN would run: {0}" -f $CheckScriptPath)
      }
    }

    if ($null -ne $outcome.Window) {
      $lastCrashDialogHandleId = [long]$outcome.Window.Handle.ToInt64()
      if ($CrashCloseClickOffsetX -ge 0 -and $CrashCloseClickOffsetY -ge 0) {
        Start-Sleep -Seconds $CrashCloseDelaySeconds
        Invoke-ClickRelativeToWindow -Handle $outcome.Window.Handle -OffsetX $CrashCloseClickOffsetX -OffsetY $CrashCloseClickOffsetY -IsDryRun ([bool]$DryRun)
      }
    }

    # * Wait before retrying after a crash.
    Write-Host "Waiting 5 seconds before retry..."
    Start-Sleep -Seconds 5
    continue
  }

  Write-Host ("Outcome: timeout after {0} seconds." -f $OutcomeTimeoutSeconds)
  if ($outcome.FabricDetected) {
    Write-Host "Fabric Loader dialog was detected during the wait."
  }
  $answer = Read-Host "Краш не обнаружен. Продолжить попытки? (y/n)"
  if ($answer -notmatch "^(y|yes|д|да)$") {
    Write-Host "Stopping by user choice."
    exit 0
  }
}

