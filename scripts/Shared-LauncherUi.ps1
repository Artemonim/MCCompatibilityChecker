# * Shared UI automation helpers for launcher control.

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
    [int]$OffsetY,
    [Parameter(Mandatory = $false)]
    [bool]$IsDryRun = $false
  )

  $rect = New-Object MCCompatWin32+RECT
  if (-not [MCCompatWin32]::GetWindowRect($Handle, [ref]$rect)) {
    throw "Failed to read window rectangle."
  }
  $targetX = $rect.Left + $OffsetX
  $targetY = $rect.Top + $OffsetY
  if ($IsDryRun) {
    Write-Host ("DRYRUN would click at: {0},{1}" -f $targetX, $targetY) -ForegroundColor Gray
    return
  }
  [void][MCCompatWin32]::SetCursorPos($targetX, $targetY)
  [MCCompatWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  [MCCompatWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
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

function Select-WindowByTitlePattern {
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

function Get-WindowHandleMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Patterns
  )

  if (-not $Patterns -or $Patterns.Count -eq 0) { return @() }

  $handles = [System.Collections.Generic.HashSet[long]]::new()
  $windows = Get-WindowList
  foreach ($window in $windows) {
    if ($null -eq $window -or $null -eq $window.Handle) { continue }
    foreach ($pattern in $Patterns) {
      if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
      if (Test-TitleMatch -Title $window.Title -Pattern $pattern) {
        $null = $handles.Add([long]$window.Handle.ToInt64())
        break
      }
    }
  }

  if ($handles.Count -eq 0) { return @() }
  return @($handles | Sort-Object -Unique)
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
    $window = Select-WindowByTitlePattern -Patterns @($TitlePattern)
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
    [int]$TimeoutSeconds,
    [Parameter(Mandatory = $false)]
    [bool]$IsDryRun = $false,
    [Parameter(Mandatory = $false)]
    [bool]$ShowWaitMessage = $false
  )

  $existing = Select-WindowByTitlePattern -Patterns @($TitlePattern)
  if ($null -ne $existing) { return $existing }

  if ([string]::IsNullOrWhiteSpace($ExePath)) {
    if ($ShowWaitMessage) {
      Write-Host "Launcher window not found. Waiting for it to appear..." -ForegroundColor Cyan
    }
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
  if ($IsDryRun) {
    if ($startArgs.Count -gt 0) {
      Write-Host ("DRYRUN would start: {0} {1}" -f $ExePath, ($startArgs -join " ")) -ForegroundColor Gray
    } else {
      Write-Host ("DRYRUN would start: {0}" -f $ExePath) -ForegroundColor Gray
    }
  } else {
    if (-not $PSCmdlet.ShouldProcess($ExePath, "Start-Process")) {
      return $null
    }
    if ($startArgs.Count -gt 0) {
      Start-Process -FilePath $ExePath -ArgumentList $startArgs | Out-Null
    } else {
      Start-Process -FilePath $ExePath | Out-Null
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
    [bool]$EnableEnterFallback,
    [Parameter(Mandatory = $true)]
    [bool]$AllowBroadSearch,
    [Parameter(Mandatory = $false)]
    [int]$PreClickDelayMs = 0,
    [Parameter(Mandatory = $false)]
    [bool]$IsDryRun = $false
  )

  [void][MCCompatWin32]::SetForegroundWindow($LauncherHandle)
  Start-Sleep -Milliseconds 150
  if ($PreClickDelayMs -gt 0) {
    Start-Sleep -Milliseconds $PreClickDelayMs
  }

  # * Prefer offset click to avoid UI Automation hangs.
  if ($ClickOffsetX -ge 0 -and $ClickOffsetY -ge 0) {
    Write-Host ("Clicking Play by offsets: X={0}, Y={1}" -f $ClickOffsetX, $ClickOffsetY) -ForegroundColor Cyan
    Invoke-ClickRelativeToWindow -Handle $LauncherHandle -OffsetX $ClickOffsetX -OffsetY $ClickOffsetY -IsDryRun $IsDryRun
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
        if ($IsDryRun) {
          Write-Host ("DRYRUN would click Play button: {0}" -f $buttonName) -ForegroundColor Gray
        } else {
          $invokePattern.Invoke()
        }
        return
      }
    }
  }

  if ($EnableEnterFallback) {
    Write-Host "Play element not found via UI Automation. Using ENTER fallback." -ForegroundColor Cyan
    [void][MCCompatWin32]::SetForegroundWindow($LauncherHandle)
    Start-Sleep -Milliseconds 150
    if ($IsDryRun) {
      Write-Host "DRYRUN would send ENTER to launcher window." -ForegroundColor Gray
    } else {
      [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    }
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
            if ($IsDryRun) {
              Write-Host ("DRYRUN would click Play element: {0}" -f $name) -ForegroundColor Gray
            } else {
              $invokePattern.Invoke()
            }
            return
          }
          $legacyPattern = $element.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern) -as [System.Windows.Automation.LegacyIAccessiblePattern]
          if ($null -ne $legacyPattern) {
            if ($IsDryRun) {
              Write-Host ("DRYRUN would activate element: {0}" -f $name) -ForegroundColor Gray
            } else {
              $legacyPattern.DoDefaultAction()
            }
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
