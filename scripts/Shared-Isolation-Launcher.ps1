function Invoke-ConfiguredLaunchAttempt {
  param(
    [Parameter(Mandatory = $false)]
    [long[]]$IgnoreHandleIds = @()
  )

  return Invoke-LaunchAttempt -LauncherTitlePattern $LauncherWindowTitlePattern `
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
    -IgnoreHandleIds $IgnoreHandleIds
}

function Wait-ConfiguredLauncherInteractive {
  [void](Wait-ForLauncherWindowInteractive -TitlePattern $LauncherWindowTitlePattern `
      -CrashPatterns $CrashWindowTitlePatterns `
      -FabricPatterns $FabricWindowTitlePatterns `
      -PollSeconds $PollIntervalSeconds)
}

function Wait-ConfiguredGameExit {
  param(
    [Parameter(Mandatory = $true)]
    [datetime]$StartedAfter,
    [Parameter(Mandatory = $false)]
    [string]$WarningContext = "Next file move"
  )

  $exited = Wait-ForGameProcessesToExit -Names $GameProcessNames `
    -StartedAfter $StartedAfter `
    -TimeoutSeconds $WaitForGameExitSeconds `
    -PollSeconds $GameExitPollSeconds
  if (-not $exited) {
    Write-Host ("Warning: game processes still running after {0}s. {1} may fail due to locks." -f $WaitForGameExitSeconds, $WarningContext) -ForegroundColor Yellow
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
    [bool]$CloseExtraFabricDialogs = $false
  )

  if ($null -eq $Outcome.Window) { return 0 }

  Write-Host ("Closing outcome window: {0} ({1})" -f $Outcome.Type, $Outcome.Window.Title) -ForegroundColor Gray
  $handleId = [long]$Outcome.Window.Handle.ToInt64()
  Close-OutcomeWindow -Outcome $Outcome `
    -DelaySeconds $DelaySeconds `
    -OffsetX $OffsetX `
    -OffsetY $OffsetY

  if ($CloseExtraFabricDialogs) {
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
  }

  # * Verify the window actually closed. If not, don't ignore it in future attempts.
  if (Test-WindowStillExists -HandleId $handleId) {
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
