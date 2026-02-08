# * Kills game processes (java/javaw/Minecraft) started after a given time.
# * Filters using Test-ProcessLooksLikeMinecraftGame to avoid killing the launcher wrapper.
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

function Resolve-IsolationLauncherContext {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  if ($null -ne $Context) { return $Context }

  $runtimeConfig = $null
  $runtimeConfigVar = Get-Variable -Name "runtimeConfig" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $runtimeConfigVar) { $runtimeConfig = $runtimeConfigVar.Value }

  $gameModsDir = ""
  $gameModsVar = Get-Variable -Name "GameModsDir" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $gameModsVar) { $gameModsDir = [string]$gameModsVar.Value }
  if ([string]::IsNullOrWhiteSpace($gameModsDir) -and $null -ne $runtimeConfig -and $null -ne $runtimeConfig.Paths) {
    $gameModsDir = [string]$runtimeConfig.Paths.GameModsDir
  }

  $launcherExePath = ""
  $launcherExeVar = Get-Variable -Name "LauncherExePath" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $launcherExeVar) { $launcherExePath = [string]$launcherExeVar.Value }
  if ([string]::IsNullOrWhiteSpace($launcherExePath) -and $null -ne $runtimeConfig -and $null -ne $runtimeConfig.Paths) {
    $launcherExePath = [string]$runtimeConfig.Paths.LauncherExePath
  }

  $waitForGameExitSeconds = 30
  $waitForGameExitVar = Get-Variable -Name "WaitForGameExitSeconds" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $waitForGameExitVar) { $waitForGameExitSeconds = [int]$waitForGameExitVar.Value }

  $gameExitPollSeconds = 2
  $gameExitPollVar = Get-Variable -Name "GameExitPollSeconds" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $gameExitPollVar) { $gameExitPollSeconds = [int]$gameExitPollVar.Value }

  $cacheEnabled = $false
  $cacheEnabledVar = Get-Variable -Name "EnableSessionLaunchConfigCache" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $cacheEnabledVar) {
    $cacheEnabled = [bool]$cacheEnabledVar.Value
  }

  $cache = @{}
  $cacheVar = Get-Variable -Name "sessionSuccessfulLaunchConfigCache" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $cacheVar -and $cacheVar.Value -is [hashtable]) {
    $cache = [hashtable]$cacheVar.Value
  }

  return [pscustomobject]@{
    Paths = [pscustomobject]@{
      GameModsDir = $gameModsDir
      LauncherExePath = $launcherExePath
    }
    Launcher = [pscustomobject]@{
      Arguments = $LauncherArguments
      UseAutoLaunch = [bool]$UseAutoLaunch
    }
    Ui = [pscustomobject]@{
      LauncherWindowTitlePattern = $LauncherWindowTitlePattern
      PlayButtonNames = $PlayButtonNames
      PlayClickOffsetX = $PlayClickOffsetX
      PlayClickOffsetY = $PlayClickOffsetY
      UseEnterFallback = [bool]$UseEnterFallback
      EnableBroadUiSearch = [bool]$EnableBroadUiSearch
      CrashWindowTitlePatterns = $CrashWindowTitlePatterns
      FabricWindowTitlePatterns = $FabricWindowTitlePatterns
      CrashCloseClickOffsetX = $CrashCloseClickOffsetX
      CrashCloseClickOffsetY = $CrashCloseClickOffsetY
    }
    Timeouts = [pscustomobject]@{
      LauncherWindowTimeoutSeconds = $LauncherWindowTimeoutSeconds
      OutcomeTimeoutSeconds = $OutcomeTimeoutSeconds
      PollIntervalSeconds = $PollIntervalSeconds
      WaitForGameExitSeconds = $waitForGameExitSeconds
      GameExitPollSeconds = $gameExitPollSeconds
      CrashCloseDelaySeconds = $CrashCloseDelaySeconds
    }
    Process = [pscustomobject]@{
      GameProcessNames = $GameProcessNames
    }
    Cache = [pscustomobject]@{
      EnableSessionLaunchConfigCache = $cacheEnabled
      SessionSuccessfulLaunchConfigCache = $cache
    }
  }
}

function Stop-GameProcess {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([int])]
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Names,
    [Parameter(Mandatory = $true)]
    [datetime]$StartedAfter,
    [Parameter(Mandatory = $false)]
    [int]$WaitAfterKillSeconds = 3
  )

  $recent = Get-RecentProcessesByName -Names $Names -StartedAfter $StartedAfter
  if (-not $recent -or $recent.Count -eq 0) { return 0 }

  $killed = 0
  foreach ($p in $recent) {
    if (-not (Test-ProcessLooksLikeMinecraftGame -Process $p)) {
      Write-Verbose ("Skipping non-game process: {0} (pid {1})" -f $p.Name, $p.Id)
      continue
    }
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

  if ($killed -gt 0 -and $WaitAfterKillSeconds -gt 0) {
    Start-Sleep -Seconds $WaitAfterKillSeconds
  }

  return $killed
}

# * Stops game processes using the configured names and waits for them to exit.
function Stop-ConfiguredGameProcess {
  [CmdletBinding(SupportsShouldProcess = $true)]
  [OutputType([int])]
  param(
    [Parameter(Mandatory = $true)]
    [datetime]$StartedAfter,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  if (-not $PSCmdlet.ShouldProcess("Minecraft game processes", "Stop")) { return 0 }
  $ctx = Resolve-IsolationLauncherContext -Context $Context
  return Stop-GameProcess -Names $ctx.Process.GameProcessNames -StartedAfter $StartedAfter
}

function Get-SessionLaunchConfigKey {
  param(
    [Parameter(Mandatory = $false)]
    [string]$ModsDir = ""
  )

  if ([string]::IsNullOrWhiteSpace($ModsDir)) { return "" }
  if (-not (Test-Path -LiteralPath $ModsDir)) { return "" }

  $jarNames = @(
    Get-ChildItem -LiteralPath $ModsDir -Filter "*.jar" -File -ErrorAction SilentlyContinue |
      ForEach-Object { [string]$_.Name } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.ToLowerInvariant() } |
      Sort-Object -Unique
  )

  if (-not $jarNames -or $jarNames.Count -eq 0) {
    return "__empty__"
  }

  return ($jarNames -join "|")
}

function Get-SessionSuccessfulLaunchConfigCache {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $ctx = Resolve-IsolationLauncherContext -Context $Context
  $cache = $null
  if ($null -ne $ctx.Cache) {
    $cache = $ctx.Cache.SessionSuccessfulLaunchConfigCache
  }
  if ($null -ne $cache -and $cache -is [hashtable]) {
    return [hashtable]$cache
  }

  $cache = @{}
  if ($null -ne $ctx.Cache) {
    $ctx.Cache.SessionSuccessfulLaunchConfigCache = $cache
  } else {
    Set-Variable -Name "sessionSuccessfulLaunchConfigCache" -Scope Script -Value $cache
  }
  return $cache
}

function Register-SessionLaunchConfigSuccess {
  param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigKey = "",
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  if ([string]::IsNullOrWhiteSpace($ConfigKey)) { return }

  $ctx = Resolve-IsolationLauncherContext -Context $Context
  $cacheEnabled = $false
  if ($null -ne $ctx.Cache) {
    $cacheEnabled = [bool]$ctx.Cache.EnableSessionLaunchConfigCache
  }
  if (-not $cacheEnabled) { return }

  $cache = Get-SessionSuccessfulLaunchConfigCache -Context $ctx
  if (-not $cache.ContainsKey($ConfigKey)) {
    $cache[$ConfigKey] = (Get-Date).ToString("o")
  }
}

function Invoke-ConfiguredLaunchAttempt {
  param(
    [Parameter(Mandatory = $false)]
    [long[]]$IgnoreHandleIds = @(),
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $ctx = Resolve-IsolationLauncherContext -Context $Context
  $cacheEnabled = $false
  if ($null -ne $ctx.Cache) {
    $cacheEnabled = [bool]$ctx.Cache.EnableSessionLaunchConfigCache
  }

  $configKey = ""
  if ($cacheEnabled) {
    $configKey = Get-SessionLaunchConfigKey -ModsDir ([string]$ctx.Paths.GameModsDir)

    if (-not [string]::IsNullOrWhiteSpace($configKey)) {
      $cache = Get-SessionSuccessfulLaunchConfigCache -Context $ctx
      if ($cache.ContainsKey($configKey)) {
        Write-Host "Session launch cache: skipping already passed mod configuration (use -NoCache to force re-check)." -ForegroundColor Gray
        return [pscustomobject]@{
          Type = "Timeout"
          Window = $null
          GameStarted = $true
          LauncherClosed = $false
          LaunchObserved = $true
          SkippedBySessionCache = $true
          LaunchConfigKey = $configKey
        }
      }
    }
  }

  $outcome = Invoke-LaunchAttempt -LauncherTitlePattern $ctx.Ui.LauncherWindowTitlePattern `
    -LauncherPath $ctx.Paths.LauncherExePath `
    -LauncherArgs $ctx.Launcher.Arguments `
    -AppendAutoLaunch ([bool]$ctx.Launcher.UseAutoLaunch) `
    -LauncherTimeoutSeconds $ctx.Timeouts.LauncherWindowTimeoutSeconds `
    -ButtonNames $ctx.Ui.PlayButtonNames `
    -ClickOffsetX $ctx.Ui.PlayClickOffsetX `
    -ClickOffsetY $ctx.Ui.PlayClickOffsetY `
    -EnableEnterFallback $ctx.Ui.UseEnterFallback `
    -AllowBroadSearch ([bool]$ctx.Ui.EnableBroadUiSearch) `
    -CrashPatterns $ctx.Ui.CrashWindowTitlePatterns `
    -FabricPatterns $ctx.Ui.FabricWindowTitlePatterns `
    -OutcomeTimeoutSeconds $ctx.Timeouts.OutcomeTimeoutSeconds `
    -PollSeconds $ctx.Timeouts.PollIntervalSeconds `
    -IgnoreHandleIds $IgnoreHandleIds

  if (-not [string]::IsNullOrWhiteSpace($configKey)) {
    try {
      Add-Member -InputObject $outcome -NotePropertyName "LaunchConfigKey" -NotePropertyValue $configKey -Force
    } catch {
      Write-Verbose ("Unable to annotate launch outcome with config key: {0}" -f $_.Exception.Message)
    }
  }

  return $outcome
}

function Wait-ConfiguredLauncherInteractive {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $ctx = Resolve-IsolationLauncherContext -Context $Context
  [void](Wait-ForLauncherWindowInteractive -TitlePattern $ctx.Ui.LauncherWindowTitlePattern `
      -CrashPatterns $ctx.Ui.CrashWindowTitlePatterns `
      -FabricPatterns $ctx.Ui.FabricWindowTitlePatterns `
      -PollSeconds $ctx.Timeouts.PollIntervalSeconds)
}

function Wait-ConfiguredGameExit {
  param(
    [Parameter(Mandatory = $true)]
    [datetime]$StartedAfter,
    [Parameter(Mandatory = $false)]
    [string]$WarningContext = "Next file move",
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $ctx = Resolve-IsolationLauncherContext -Context $Context
  $exited = Wait-ForGameProcessesToExit -Names $ctx.Process.GameProcessNames `
    -StartedAfter $StartedAfter `
    -TimeoutSeconds $ctx.Timeouts.WaitForGameExitSeconds `
    -PollSeconds $ctx.Timeouts.GameExitPollSeconds
  if (-not $exited) {
    Write-Host ("Warning: game processes still running after {0}s. {1} may fail due to locks." -f $ctx.Timeouts.WaitForGameExitSeconds, $WarningContext) -ForegroundColor Yellow
  }
  return $exited
}

function Close-OutcomeWindowWithExtraDialog {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Outcome,
    [Parameter(Mandatory = $true)]
    [int]$DelaySeconds,
    [Parameter(Mandatory = $true)]
    [int]$OffsetX,
    [Parameter(Mandatory = $true)]
    [int]$OffsetY,
    [Parameter(Mandatory = $false)]
    [bool]$CloseExtraFabricDialogs = $false,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  if ($null -eq $Outcome.Window) { return 0 }

  $ctx = Resolve-IsolationLauncherContext -Context $Context
  Write-Host ("Closing outcome window: {0} ({1})" -f $Outcome.Type, $Outcome.Window.Title) -ForegroundColor Gray
  $handleId = [long]$Outcome.Window.Handle.ToInt64()
  Close-OutcomeWindow -Outcome $Outcome `
    -DelaySeconds $DelaySeconds `
    -OffsetX $OffsetX `
    -OffsetY $OffsetY

  if ($CloseExtraFabricDialogs) {
    # * Some launchers show both a generic crash dialog and Fabric's incompatibility dialog.
    # * Close Fabric dialog too to keep automation continuous.
    $extraFabricWindow = Select-WindowByTitlePattern -Patterns $ctx.Ui.FabricWindowTitlePatterns
    if ($null -ne $extraFabricWindow) {
      Write-Host ("Closing extra Fabric Loader dialog: {0}" -f $extraFabricWindow.Title) -ForegroundColor Gray
      Close-OutcomeWindow -Outcome ([pscustomobject]@{ Type = "FabricDialog"; Window = $extraFabricWindow }) `
        -DelaySeconds 0 `
        -OffsetX -1 `
        -OffsetY -1
    }
  }

  # * Verify the window actually closed. If not, don't ignore it in future attempts.
  if (Test-WindowPresence -HandleId $handleId) {
    Write-Host ("Warning: outcome window did not close ({0}). It will be detected again on next attempt." -f $Outcome.Type) -ForegroundColor Yellow
    return 0
  }

  return $handleId
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
    $fabricWindow = Select-WindowByTitlePattern -Patterns $FabricPatterns -ExcludeHandleIds $IgnoreHandleIds
    if ($null -ne $fabricWindow) {
      return [pscustomobject]@{
        Type = "FabricDialog"
        Window = $fabricWindow
        GameStarted = $gameStarted
        LauncherClosed = $launcherClosed
        LaunchObserved = $true
      }
    }

    $crashWindow = Select-WindowByTitlePattern -Patterns $CrashPatterns -ExcludeHandleIds $IgnoreHandleIds
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
      $latestTlLog = Get-LatestTLauncherLogPath -PreferredPath "" -AllowMissing $true
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
        # * Crash/Fabric dialogs may appear with delay after process exit.
        $postExitDeadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $postExitDeadline) {
          $fabricAfterExit = Select-WindowByTitlePattern -Patterns $FabricPatterns -ExcludeHandleIds $IgnoreHandleIds
          if ($null -ne $fabricAfterExit) {
            return [pscustomobject]@{
              Type = "FabricDialog"
              Window = $fabricAfterExit
              GameStarted = $gameStarted
              LauncherClosed = $launcherClosed
              LaunchObserved = $true
            }
          }
          $crashAfterExit = Select-WindowByTitlePattern -Patterns $CrashPatterns -ExcludeHandleIds $IgnoreHandleIds
          if ($null -ne $crashAfterExit) {
            return [pscustomobject]@{
              Type = "CrashDialog"
              Window = $crashAfterExit
              GameStarted = $gameStarted
              LauncherClosed = $launcherClosed
              LaunchObserved = $true
            }
          }
          Start-Sleep -Milliseconds 250
        }

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
      if (-not (Test-WindowPresence -HandleId $LauncherHandleId)) {
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

  # * Late outcome check: dialogs/process exit can occur at the timeout boundary.
  $fabricWindowLate = Select-WindowByTitlePattern -Patterns $FabricPatterns -ExcludeHandleIds $IgnoreHandleIds
  if ($null -ne $fabricWindowLate) {
    return [pscustomobject]@{
      Type = "FabricDialog"
      Window = $fabricWindowLate
      GameStarted = $gameStarted
      LauncherClosed = $launcherClosed
      LaunchObserved = $true
    }
  }

  $crashWindowLate = Select-WindowByTitlePattern -Patterns $CrashPatterns -ExcludeHandleIds $IgnoreHandleIds
  if ($null -ne $crashWindowLate) {
    return [pscustomobject]@{
      Type = "CrashDialog"
      Window = $crashWindowLate
      GameStarted = $gameStarted
      LauncherClosed = $launcherClosed
      LaunchObserved = $true
    }
  }

  if ($gameObservedOnce -and $observedGamePids.Count -gt 0) {
    foreach ($processId in @($observedGamePids.Keys)) {
      $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
      if ($null -eq $proc) {
        $null = $observedGamePids.Remove($processId)
        $gameExited = $true
      }
    }
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
    # * Final boundary check: delayed dialogs can appear after game exit.
    $postExitLateDeadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $postExitLateDeadline) {
      $fabricAfterExitLate = Select-WindowByTitlePattern -Patterns $FabricPatterns -ExcludeHandleIds $IgnoreHandleIds
      if ($null -ne $fabricAfterExitLate) {
        return [pscustomobject]@{
          Type = "FabricDialog"
          Window = $fabricAfterExitLate
          GameStarted = $gameStarted
          LauncherClosed = $launcherClosed
          LaunchObserved = $launchTriggered
        }
      }
      $crashAfterExitLate = Select-WindowByTitlePattern -Patterns $CrashPatterns -ExcludeHandleIds $IgnoreHandleIds
      if ($null -ne $crashAfterExitLate) {
        return [pscustomobject]@{
          Type = "CrashDialog"
          Window = $crashAfterExitLate
          GameStarted = $gameStarted
          LauncherClosed = $launcherClosed
          LaunchObserved = $launchTriggered
        }
      }
      Start-Sleep -Milliseconds 250
    }

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
  if (Test-WindowPresence -HandleId $handleId) {
    [void][MCCompatWin32]::SetForegroundWindow($Outcome.Window.Handle)
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.SendKeys]::SendWait("%{F4}")
    Start-Sleep -Milliseconds 500
  }

  if (Test-WindowPresence -HandleId $handleId) {
    Request-UserToCloseBlockingWindow -HandleId $handleId -WindowTitle $Outcome.Window.Title
  }
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
  # * Retry counter: wait and retry before prompting the user.
  # * The launcher may be temporarily invisible while re-rendering or
  # * a transient overlay window (e.g. from the game restart) may block detection.
  $unknownRetryCount = 0
  $unknownRetryMax = 3
  $unknownRetryDelaySeconds = 5
  while ($true) {
    $fabricWindow = Select-WindowByTitlePattern -Patterns $FabricPatterns
    if ($null -ne $fabricWindow) {
      Write-Host ("Blocking Fabric dialog detected: {0}" -f $fabricWindow.Title) -ForegroundColor Yellow
      Close-OutcomeWindow -Outcome ([pscustomobject]@{ Type = "FabricDialog"; Window = $fabricWindow }) `
        -DelaySeconds 0 `
        -OffsetX -1 `
        -OffsetY -1
      Start-Sleep -Seconds $PollSeconds
      $unknownRetryCount = 0
      continue
    }

    $crashWindow = Select-WindowByTitlePattern -Patterns $CrashPatterns
    if ($null -ne $crashWindow) {
      Write-Host ("Blocking crash dialog detected: {0}" -f $crashWindow.Title) -ForegroundColor Yellow
      Close-OutcomeWindow -Outcome ([pscustomobject]@{ Type = "CrashDialog"; Window = $crashWindow }) `
        -DelaySeconds 0 `
        -OffsetX -1 `
        -OffsetY -1
      Start-Sleep -Seconds $PollSeconds
      $unknownRetryCount = 0
      continue
    }

    $launcherWindow = Select-WindowByTitlePattern -Patterns @($TitlePattern)
    if ($null -ne $launcherWindow) { return $launcherWindow }

    # * No known window found. Retry silently before prompting the user.
    $unknownRetryCount++
    if ($unknownRetryCount -le $unknownRetryMax) {
      Write-Host ("Launcher window not found (attempt {0}/{1}). Retrying in {2}s..." -f $unknownRetryCount, $unknownRetryMax, $unknownRetryDelaySeconds) -ForegroundColor Yellow
      Start-Sleep -Seconds $unknownRetryDelaySeconds
      continue
    }

    [void][System.Windows.Forms.MessageBox]::Show(
      $promptMessage,
      "Требуется действие пользователя",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    Start-Sleep -Seconds $PollSeconds
    # * Reset counter after the user acknowledges — they may have closed the blocker.
    $unknownRetryCount = 0
  }
}

function Request-LauncherRecoveryDecision {
  param(
    [Parameter(Mandatory = $false)]
    [int]$PlayAttempts = 0
  )

  $attemptLabel = if ($PlayAttempts -gt 0) {
    ("Попыток запуска: {0}." -f $PlayAttempts)
  } else {
    "Попытка запуска не обнаружена."
  }

  $prompt = @(
    "Невозможно запустить или обнаружить лаунчер. Попробуйте перезапустить лаунчер."
    $attemptLabel
    ""
    "Да — продолжить попытки."
    "Нет — отменить."
    "Отмена — отменить с откатом изменений."
  ) -join [Environment]::NewLine

  $result = [System.Windows.Forms.MessageBox]::Show(
    $prompt,
    "Требуется действие пользователя",
    [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
    [System.Windows.Forms.MessageBoxIcon]::Warning
  )

  switch ($result) {
    ([System.Windows.Forms.DialogResult]::Yes) { return "continue" }
    ([System.Windows.Forms.DialogResult]::No) { return "cancel_keep" }
    default { return "cancel_rollback" }
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
  $strayCrash = Select-WindowByTitlePattern -Patterns $CrashPatterns
  if ($null -ne $strayCrash) {
    Write-Host ("Closing stray crash dialog before launching: {0}" -f $strayCrash.Title) -ForegroundColor Gray
    Close-OutcomeWindow -Outcome ([pscustomobject]@{ Type = "CrashDialog"; Window = $strayCrash }) `
      -DelaySeconds 0 `
      -OffsetX -1 `
      -OffsetY -1
  }
  $strayFabric = Select-WindowByTitlePattern -Patterns $FabricPatterns
  if ($null -ne $strayFabric) {
    Write-Host ("Closing stray Fabric Loader dialog before launching: {0}" -f $strayFabric.Title) -ForegroundColor Gray
    Close-OutcomeWindow -Outcome ([pscustomobject]@{ Type = "FabricDialog"; Window = $strayFabric }) `
      -DelaySeconds 0 `
      -OffsetX -1 `
      -OffsetY -1
  }

  $launcherWindow = $null
  try {
    $launcherWindow = Start-LauncherIfNeeded -TitlePattern $LauncherTitlePattern `
      -ExePath $LauncherPath `
      -ExeArguments $LauncherArgs `
      -AppendAutoLaunch $AppendAutoLaunch `
      -TimeoutSeconds $LauncherTimeoutSeconds
  } catch {
    $message = [string]$_.Exception.Message
    if ($message -match "Launcher window not found") {
      $launcherWindow = Wait-ForLauncherWindowInteractive -TitlePattern $LauncherTitlePattern `
        -CrashPatterns $CrashPatterns `
        -FabricPatterns $FabricPatterns `
        -PollSeconds $PollSeconds
    } else {
      throw
    }
  }

  if ($null -eq $launcherWindow) {
    $launcherWindow = Wait-ForLauncherWindowInteractive -TitlePattern $LauncherTitlePattern `
      -CrashPatterns $CrashPatterns `
      -FabricPatterns $FabricPatterns `
      -PollSeconds $PollSeconds
  }

  if ($null -eq $launcherWindow) {
    throw "Launcher window not found."
  }

  $launcherHandleId = [long]$launcherWindow.Handle.ToInt64()

  $maxPlayAttempts = $PlayClickMaxAttempts
  if ($maxPlayAttempts -lt 1) { $maxPlayAttempts = 1 }
  if ($LaunchStartTimeoutSeconds -gt $OutcomeTimeoutSeconds) {
    $LaunchStartTimeoutSeconds = $OutcomeTimeoutSeconds
  }

  while ($true) {
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

    $decision = Request-LauncherRecoveryDecision -PlayAttempts $maxPlayAttempts
    if ($decision -eq "continue") {
      Write-Host "Продолжаю попытки запуска после действия пользователя." -ForegroundColor Cyan
      $launcherWindow = Select-WindowByTitlePattern -Patterns @($LauncherTitlePattern)
      if ($null -eq $launcherWindow) {
        $launcherWindow = Wait-ForLauncherWindowInteractive -TitlePattern $LauncherTitlePattern `
          -CrashPatterns $CrashPatterns `
          -FabricPatterns $FabricPatterns `
          -PollSeconds $PollSeconds
      }
      if ($null -eq $launcherWindow) {
        throw "Launcher window not found after user requested continue."
      }
      $launcherHandleId = [long]$launcherWindow.Handle.ToInt64()
      continue
    }

    if ($decision -eq "cancel_keep") {
      throw [System.OperationCanceledException]::new("MCCompatUserCancelKeepChanges: launcher start canceled by user.")
    }
    throw [System.OperationCanceledException]::new("MCCompatUserCancelRollback: launcher start canceled by user.")
  }
}
