Write-Host ("Launcher title pattern: {0}" -f $LauncherWindowTitlePattern) -ForegroundColor Cyan
Write-Host "Attempt limit: unlimited" -ForegroundColor Gray
$launcherWindow = $null
$lastCrashDialogHandleId = 0
$inputKeyRetryYes = "y"
$inputKeyRetryNo = "n"
$inputKeyRunRecovery = "r"
$inputKeyRollbackExit = "n"
$inputKeyAcceptExit = "s"
$inputKeyHintRetry = "{0}/{1}" -f $inputKeyRetryYes, $inputKeyRetryNo
$inputKeyHintIsolants = "{0}/{1}/{2}" -f $inputKeyRunRecovery, $inputKeyRollbackExit, $inputKeyAcceptExit

if (Get-Command -Name Set-McccLocalizationTagValue -ErrorAction SilentlyContinue) {
  Set-McccLocalizationTagValue -TagMap @{
    "<KEY_RETRY_YES>" = $inputKeyRetryYes
    "<KEY_RETRY_NO>" = $inputKeyRetryNo
    "<KEY_CONTINUE_AS_IS>" = $inputKeyRunRecovery
    "<KEY_RESTORE_CONTINUE>" = $inputKeyRollbackExit
    "<KEY_RESTORE_EXIT>" = $inputKeyRollbackExit
    "<KEY_KEEP_EXIT>" = $inputKeyAcceptExit
    "<KEY_RETRY_HINT>" = $inputKeyHintRetry
    "<KEY_ISOLANTS_HINT>" = $inputKeyHintIsolants
  }
}

$regexRetryYes = "^(?:{0}|yes)$" -f [regex]::Escape($inputKeyRetryYes)
$regexChoiceRunRecovery = "^(?:{0}|recovery|recover)$" -f [regex]::Escape($inputKeyRunRecovery)
$regexChoiceRollbackExit = "^(?:{0}|restore|rollback|undo|{1}|no)$" -f [regex]::Escape($inputKeyRollbackExit), [regex]::Escape($inputKeyRetryNo)
$regexChoiceAcceptExit = "^(?:{0}|accept|keep|skip|stop)$" -f [regex]::Escape($inputKeyAcceptExit)

function Invoke-PreLaunchOutcomeDialogCleanup {
  [CmdletBinding()]
  [OutputType([long[]])]
  param(
    [Parameter(Mandatory = $false)]
    [int]$MaxPasses = 6,
    [Parameter(Mandatory = $false)]
    [int[]]$ProcessIds = @()
  )

  if ($MaxPasses -lt 1) { $MaxPasses = 1 }
  $ignoredHandleIds = [System.Collections.Generic.HashSet[long]]::new()

  for ($pass = 1; $pass -le $MaxPasses; $pass++) {
    $closedThisPass = $false

    $fabricWindow = Select-WindowByTitlePattern -Patterns $FabricWindowTitlePatterns -ProcessIds $ProcessIds
    if ($null -ne $fabricWindow) {
      Write-Host ("Closing pre-existing Fabric dialog before launch: {0}" -f $fabricWindow.Title) -ForegroundColor Gray
      $fabricHandle = Close-OutcomeWindowWithExtraDialog -Outcome ([pscustomobject]@{ Type = "FabricDialog"; Window = $fabricWindow }) `
        -DelaySeconds 0 `
        -OffsetX -1 `
        -OffsetY -1 `
        -CloseExtraFabricDialogs $false
      if ($fabricHandle -ne 0) {
        $null = $ignoredHandleIds.Add([long]$fabricHandle)
        $closedThisPass = $true
      }
    }

    $crashWindow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns -ProcessIds $ProcessIds
    if ($null -ne $crashWindow) {
      Write-Host ("Closing pre-existing crash dialog before launch: {0}" -f $crashWindow.Title) -ForegroundColor Gray
      $crashHandle = Close-OutcomeWindowWithExtraDialog -Outcome ([pscustomobject]@{ Type = "CrashDialog"; Window = $crashWindow }) `
        -DelaySeconds 0 `
        -OffsetX -1 `
        -OffsetY -1 `
        -CloseExtraFabricDialogs $true
      if ($crashHandle -ne 0) {
        $null = $ignoredHandleIds.Add([long]$crashHandle)
        $closedThisPass = $true
      }
    }

    if (-not $closedThisPass) {
      break
    }
  }

  # * Fallback: if a stale dialog refused to close, ignore it for outcome detection.
  $leftoverHandles = @(Get-WindowHandleMatch -Patterns @($CrashWindowTitlePatterns + $FabricWindowTitlePatterns) -ProcessIds $ProcessIds)
  if ($leftoverHandles.Count -gt 0) {
    Write-Host ("Warning: {0} pre-existing crash/fabric dialog window(s) are still open and will be ignored in this attempt." -f $leftoverHandles.Count) -ForegroundColor Yellow
    foreach ($id in $leftoverHandles) {
      if ($null -eq $id -or [long]$id -eq 0) { continue }
      $null = $ignoredHandleIds.Add([long]$id)
    }
  }

  if ($ignoredHandleIds.Count -eq 0) { return [long[]]@() }
  return [long[]]($ignoredHandleIds | Sort-Object -Unique)
}

function Invoke-PostSessionOutcomeDialogCleanup {
  if ($DryRun) { return }
  $finalCrashWindow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
  if ($null -ne $finalCrashWindow) {
    Write-Host ("Closing remaining crash window: {0}" -f $finalCrashWindow.Title) -ForegroundColor Gray
    [void](Close-OutcomeWindowWithExtraDialog -Outcome ([pscustomobject]@{ Type = "CrashDialog"; Window = $finalCrashWindow }) `
      -DelaySeconds $CrashCloseDelaySeconds `
      -OffsetX $CrashCloseClickOffsetX `
      -OffsetY $CrashCloseClickOffsetY `
      -CloseExtraFabricDialogs $true)
  }
}

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
$sessionGameModsDir = ""
$sessionStorageModsDir = ""
if ($null -ne $runtimeConfig -and $null -ne $runtimeConfig.Paths) {
  $sessionGameModsDir = [string]$runtimeConfig.Paths.GameModsDir
  $sessionStorageModsDir = [string]$runtimeConfig.Paths.StorageModsDir
}

# * Log snapshot defaults for Fabric dialog auto-handling.
$autoFabricLogMaxAgeMinutes = 30
$autoFabricLogReadRetryCount = 5
$autoFabricLogReadRetryDelayMs = 500
$autoFabricLogSinceSkewSeconds = 120
$autoFabricSkipGameLogs = $false

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
    $answer = Read-Host "Launcher not found. Continue retrying? (<KEY_RETRY_HINT>)"
    if ($answer -notmatch $regexRetryYes) {
      Write-Host "Stopping by user choice." -ForegroundColor Yellow
      Invoke-PostSessionOutcomeDialogCleanup
      exit 0
    }
    Write-Host ("Retrying in {0}s." -f $PollIntervalSeconds) -ForegroundColor Yellow
    Start-Sleep -Seconds $PollIntervalSeconds
    continue
  }

  if (-not $DryRun) {
    $activeGamePids = New-Object System.Collections.Generic.List[int]
    $recentGameProcesses = Get-RecentProcessesByName -Names $GameProcessNames -StartedAfter $sessionStartTime
    foreach ($proc in @($recentGameProcesses)) {
      if (Test-ProcessLooksLikeMinecraftGame -Process $proc) {
        $activeGamePids.Add([int]$proc.Id) | Out-Null
      }
    }
    if ($activeGamePids.Count -gt 0) {
      $pidLabel = (@($activeGamePids | Sort-Object -Unique) -join ", ")
      Write-Host ("Game is still running (pid: {0}). Waiting for it to exit before next Play click..." -f $pidLabel) -ForegroundColor Yellow
      $exitedBeforeRetry = Wait-ConfiguredGameExit -StartedAfter $sessionStartTime -WarningContext "next launch attempt"
      if (-not $exitedBeforeRetry) {
        Write-Host ("Game is still running. Retrying check in {0}s..." -f $PollIntervalSeconds) -ForegroundColor Yellow
        Start-Sleep -Seconds $PollIntervalSeconds
        continue
      }
    }
  }

  $launcherProcessIds = @()
  $launcherProcessId = Get-WindowProcessId -Handle $launcherWindow.Handle
  if ($launcherProcessId -gt 0) {
    $launcherProcessIds = @([int]$launcherProcessId)
  }

  $preLaunchIgnoredOutcomeIds = @()
  if (-not $DryRun) {
    $preLaunchIgnoredOutcomeIds = @(Invoke-PreLaunchOutcomeDialogCleanup -ProcessIds $launcherProcessIds)
  }

  # * Capture pre-existing crash/fabric windows BEFORE clicking Play.
  # * Keep both launcher-scoped and global handles to avoid treating stale dialogs as a new outcome.
  $preExistingOutcomeHandleSet = [System.Collections.Generic.HashSet[long]]::new()
  $preExistingOutcomeHandlesScoped = @(Get-WindowHandleMatch -Patterns @($CrashWindowTitlePatterns + $FabricWindowTitlePatterns) -ProcessIds $launcherProcessIds)
  $preExistingOutcomeHandlesGlobal = @(Get-WindowHandleMatch -Patterns @($CrashWindowTitlePatterns + $FabricWindowTitlePatterns))
  foreach ($id in @($preExistingOutcomeHandlesScoped + $preExistingOutcomeHandlesGlobal)) {
    if ($null -eq $id -or [long]$id -eq 0) { continue }
    $null = $preExistingOutcomeHandleSet.Add([long]$id)
  }
  $preExistingOutcomeHandles = @($preExistingOutcomeHandleSet | Sort-Object -Unique)

  Invoke-LauncherPlay -LauncherHandle $launcherWindow.Handle `
    -ButtonNames $PlayButtonNames `
    -ClickOffsetX $PlayClickOffsetX `
    -ClickOffsetY $PlayClickOffsetY `
    -EnableEnterFallback $UseEnterFallback `
    -AllowBroadSearch ([bool]$EnableBroadUiSearch) `
    -IsDryRun ([bool]$DryRun)

  $launchStart = Get-Date
  $ignoreCrashIds = @()
  if ($lastCrashDialogHandleId -ne 0 -and (Test-WindowPresence -HandleId $lastCrashDialogHandleId)) {
    $ignoreCrashIds = @($lastCrashDialogHandleId)
  } else {
    $lastCrashDialogHandleId = 0
  }
  $ignoreHandleSet = [System.Collections.Generic.HashSet[long]]::new()
  foreach ($id in @($ignoreCrashIds + $preLaunchIgnoredOutcomeIds + $preExistingOutcomeHandles)) {
    if ($null -eq $id -or [long]$id -eq 0) { continue }
    $null = $ignoreHandleSet.Add([long]$id)
  }
  $ignoreOutcomeHandleIds = @($ignoreHandleSet | Sort-Object -Unique)

  $outcome = Wait-ForOutcome -CrashPatterns $CrashWindowTitlePatterns `
    -FabricPatterns $FabricWindowTitlePatterns `
    -TimeoutSeconds $OutcomeTimeoutSeconds `
    -PollSeconds $PollIntervalSeconds `
    -LaunchStart $launchStart `
    -GameProcessNames $GameProcessNames `
    -LauncherHandleId ([long]$launcherWindow.Handle.ToInt64()) `
    -LaunchStartTimeoutSeconds $SuccessGraceSeconds `
    -RequireGameStartForTimeout ([bool]($SuccessGraceSeconds -gt 0)) `
    -IgnoreHandleIds $ignoreOutcomeHandleIds

  # * Race guard: a crash/fabric dialog can appear right after Wait-ForOutcome returns.
  # * Re-check for a short grace window before branching into outcome handling.
  if ($outcome.Type -eq "Timeout") {
    $lateDeadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $lateDeadline -and $outcome.Type -eq "Timeout") {
      $lateCrashNow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns -ExcludeHandleIds $ignoreOutcomeHandleIds -ProcessIds $launcherProcessIds
      if ($null -ne $lateCrashNow) {
        Write-Host ("Late crash dialog detected after probe window: {0}" -f $lateCrashNow.Title) -ForegroundColor Yellow
        $outcome = [pscustomobject]@{ Type = "CrashDialog"; Window = $lateCrashNow }
        break
      }
      $lateFabricNow = Select-WindowByTitlePattern -Patterns $FabricWindowTitlePatterns -ExcludeHandleIds $ignoreOutcomeHandleIds -ProcessIds $launcherProcessIds
      if ($null -ne $lateFabricNow) {
        Write-Host ("Late Fabric dialog detected after probe window: {0}" -f $lateFabricNow.Title) -ForegroundColor Yellow
        $outcome = [pscustomobject]@{ Type = "FabricDialog"; Window = $lateFabricNow }
        break
      }
      Start-Sleep -Milliseconds 300
    }
  }

  $launchWasSuccessful = ($outcome.Type -eq "Timeout" -or $outcome.Type -eq "ProcessExit")
  if ((-not $launchWasSuccessful) -and (-not [bool]$script:sessionDependencyMapPrepared) -and (-not $DryRun)) {
    $depReason = "attempt {0}: {1}" -f $attempt, $outcome.Type
    [void](Initialize-SessionDependencyMap -Reason $depReason)
  }

  $fabricMissingDepsDetected = $false
  $fabricMissingDepIds = @()
  $fabricRequiringModIds = @()
  $fabricRoutedToCleanup = $false

  # * Route Fabric "remove/replace" outcomes into the same debug pipeline as crash dialogs.
  if ($outcome.Type -eq "FabricDialog" -and $AutoHandleFabricDialog -and -not $DryRun) {
    $fabricShouldRunCleanup = $false
    $logSnapshot = $null
    try {
      $gameModsDirForLogs = ""
      if ($null -ne $runtimeConfig -and $null -ne $runtimeConfig.Paths) {
        $gameModsDirForLogs = [string]$runtimeConfig.Paths.GameModsDir
      }
      $logSnapshot = Get-LogSnapshot -PrimaryLogPath $LogPath `
        -GameModsDir $gameModsDirForLogs `
        -SkipGameLogs $autoFabricSkipGameLogs `
        -LogMaxAgeMinutes $autoFabricLogMaxAgeMinutes `
        -LogReadRetryCount $autoFabricLogReadRetryCount `
        -LogReadRetryDelayMs $autoFabricLogReadRetryDelayMs `
        -SinceTimestamp $launchStart `
        -SinceTimestampSkewSeconds $autoFabricLogSinceSkewSeconds
    } catch {
      Write-Host ("Warning: failed to read logs for Fabric pre-routing: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

    if ($null -ne $logSnapshot -and $logSnapshot.Lines.Count -gt 0) {
      $depInfo = Get-FabricDependencyDialogInfo -Lines $logSnapshot.Lines
      if ($depInfo.HasMissingDeps) {
        $fabricMissingDepsDetected = $true
        $fabricMissingDepIds = @($depInfo.MissingDepIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        $fabricRequiringModIds = @($depInfo.RequiringModIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        $missLabel = if ($fabricMissingDepIds.Count -gt 0) { $fabricMissingDepIds -join ", " } else { "<none>" }
        $reqLabel = if ($fabricRequiringModIds.Count -gt 0) { $fabricRequiringModIds -join ", " } else { "<none>" }
        Write-Host ("Fabric dialog shows missing dependencies: {0}. User action is required." -f $missLabel) -ForegroundColor Yellow
        Write-Host ("Requiring mods: {0}" -f $reqLabel) -ForegroundColor Gray

        # * Mirror key Fabric dialog lines in console so the user can review details without switching windows.
        $fabricDependencyDetailLines = @(
          $logSnapshot.Lines |
            ForEach-Object { [string]$_ } |
            Where-Object {
              $_ -match "(?i)^\s*-\s+(Remove|Replace)\s+mod\b" -or
              $_ -match "(?i)requires\s+.+\s+which\s+is\s+missing" -or
              $_ -match "(?i)Could\s+not\s+find\s+required\s+mod:" -or
              $_ -match "(?i)is\s+required\s+to\s+run\s+the\s+following\s+mods?\b" -or
              $_ -match "(?i)^\s*Some\s+of\s+your\s+mods\s+are\s+incompatible\b" -or
              $_ -match "(?i)^\s*A\s+potential\s+solution\s+has\s+been\s+determined\b" -or
              $_ -match "(?i)^\s*More\s+details:\s*$"
            } |
            ForEach-Object { ConvertTo-NormalizedLogLine -Line $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -Unique |
            Select-Object -First 40
        )
        if ($fabricDependencyDetailLines.Count -gt 0) {
          Write-Host "Key Fabric dialog lines (from logs):" -ForegroundColor Gray
          foreach ($detailLine in $fabricDependencyDetailLines) {
            Write-Host ("  - {0}" -f $detailLine) -ForegroundColor Gray
          }
        }
      } else {
        $incompatibleIds = @(Get-IncompatibleModIdsFromLog -Lines $logSnapshot.Lines -IncludeWarnMixins $false) |
          ForEach-Object { [string]$_ } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
          Sort-Object -Unique
        $incompatibleIds = @($incompatibleIds)

        $filteredIds = $incompatibleIds
        if ($IgnoreModIds -and $IgnoreModIds.Count -gt 0 -and $incompatibleIds.Count -gt 0) {
          $ignoreSet = @{}
          foreach ($id in $IgnoreModIds) {
            $key = [string]$id
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $ignoreSet[$key.ToLowerInvariant()] = $true
          }
          if ($ignoreSet.Count -gt 0) {
            $filteredIds = @($incompatibleIds | Where-Object { -not $ignoreSet.ContainsKey($_.ToLowerInvariant()) })
            $ignoredIds = @($incompatibleIds | Where-Object { $ignoreSet.ContainsKey($_.ToLowerInvariant()) })
            if ($ignoredIds.Count -gt 0) {
              Write-Host ("Ignoring mod IDs from ignore list: {0}" -f ($ignoredIds -join ", ")) -ForegroundColor Gray
            }
          }
        }

        if ($filteredIds.Count -gt 0) {
          Write-Host ("Fabric dialog has no missing dependencies. Routing to debug pipeline (mods: {0})." -f ($filteredIds -join ", ")) -ForegroundColor Cyan
          $fabricShouldRunCleanup = $true
        } elseif ($incompatibleIds.Count -gt 0) {
          Write-Host "All incompatible mod IDs are in the ignore list. User action is required." -ForegroundColor Yellow
        } else {
          Write-Host "Fabric dialog has no missing dependencies, but mod IDs were not found in logs. Routing to debug pipeline." -ForegroundColor Yellow
          $fabricShouldRunCleanup = $true
        }
      }
    } else {
      $fabricMissingDepsDetected = $true
      $fabricMissingDepIds = @()
      $fabricRequiringModIds = @()
      Write-Host ("Fabric dialog shows missing dependencies: {0}. User action is required." -f "<unknown>") -ForegroundColor Yellow
      Write-Host ("Requiring mods: {0}" -f "<unknown>") -ForegroundColor Gray
    }

    if ($fabricShouldRunCleanup) {
      Write-Host "Routing Fabric dialog to compatibility cleanup pipeline." -ForegroundColor Cyan
      $fabricRoutedToCleanup = $true
      $outcome = [pscustomobject]@{ Type = "CrashDialog"; Window = $outcome.Window }
    }
  }

  if ($outcome.Type -eq "CrashDialog") {
    Write-Host "Outcome: crash dialog detected. Running Baseline Analysis." -ForegroundColor Yellow

    # * Ensure the game is fully closed before any mod file operations.
    # * Without this, layering/isolation can hit file locks in initial quarantine.
    if (-not $DryRun) {
      $closedBeforeCleanup = Stop-GameProcess -Names $GameProcessNames -StartedAfter $sessionStartTime
      if ($closedBeforeCleanup -gt 0) {
        Write-Host ("Closed {0} running game process(es) before cleanup." -f $closedBeforeCleanup) -ForegroundColor Gray
      }
      $allExitedBeforeCleanup = Wait-ConfiguredGameExit -StartedAfter $sessionStartTime -WarningContext "Compatibility cleanup"
      if (-not $allExitedBeforeCleanup) {
        $closedLateBeforeCleanup = Stop-GameProcess -Names $GameProcessNames -StartedAfter $sessionStartTime
        if ($closedLateBeforeCleanup -gt 0) {
          Write-Host ("Closed {0} late game process(es) before cleanup." -f $closedLateBeforeCleanup) -ForegroundColor Gray
        }
        [void](Wait-ConfiguredGameExit -StartedAfter $sessionStartTime -WarningContext "Compatibility cleanup")
      }
    }

    if (([bool]$UseHashCache) -and $script:hashCacheAttemptedThisSession -and (-not $script:hashCacheDisabledThisSession)) {
      Write-Host "Hash cache did not resolve the crash in this session. Retrying without hashes." -ForegroundColor Yellow
      $script:hashCacheDisabledThisSession = $true
    }

    if (-not $DryRun) {
      $compatParams = Get-CompatibilityParam -LogSinceTimestamp $launchStart
      $compatExtraArgs = Get-CompatibilityExtraArg
      $forwardVerbose = [bool]$PSBoundParameters.ContainsKey("Verbose")
      $hasVerboseArg = $false
      foreach ($arg in $compatExtraArgs) {
        if ($arg -ieq "-Verbose") { $hasVerboseArg = $true; break }
      }
      if ($hasVerboseArg) {
        & $CheckScriptPath @compatParams @compatExtraArgs
      } else {
        & $CheckScriptPath @compatParams @compatExtraArgs -Verbose:$forwardVerbose
      }
      $compatExitCode = $LASTEXITCODE

      $latestCompatReportPathForAttempt = ""
      $compatReportMoves = @()
      try {
        $latestCompatReportPathForAttempt = Get-LatestCompatReportPath `
          -ReportDir $script:compatReportDir `
          -SinceTimestamp $launchStart `
          -SinceSkewSeconds 10
        if (-not [string]::IsNullOrWhiteSpace($latestCompatReportPathForAttempt) -and (Test-Path -LiteralPath $latestCompatReportPathForAttempt)) {
          $compatReportMoves = @(Get-CompatHandledCulpritMove `
              -CompatReportPath $latestCompatReportPathForAttempt `
              -GameModsDir $sessionGameModsDir `
              -StorageModsDir $sessionStorageModsDir)
        }
      } catch {
        Write-Host ("Warning: failed to parse compatibility report for session history: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
      }
      if ($compatReportMoves.Count -gt 0) {
        $compatAddedCount = 0
        foreach ($move in $compatReportMoves) {
          if ($null -eq $move) { continue }
          $name = [string]$move.JarName
          if ([string]::IsNullOrWhiteSpace($name)) { continue }
          $nameKey = $name.ToLowerInvariant()
          if (-not $sessionIsolationCulpritHistoryByJar.ContainsKey($nameKey)) {
            $compatAddedCount++
          }
          $sessionIsolationCulpritByJar[$nameKey] = $move
          $sessionIsolationCulpritHistoryByJar[$nameKey] = $move
        }
        if ($compatAddedCount -gt 0) {
          Write-Host ("Baseline Analysis isolated {0} mod(s) in this attempt." -f $compatAddedCount) -ForegroundColor Gray
        }
      }

      if ($compatExitCode -ne 0) {
        if ($compatExitCode -eq 130) {
          $sessionInterrupted = $true
        }
        if ($compatExitCode -eq 3) {
          $skipDeepPipelineForFabric = $false
          if ($fabricRoutedToCleanup) {
            $skipDeepPipelineForFabric = $true
            $fabricHandledModIds = @()
            $fabricUnresolvedModIds = @()
            try {
              $latestCompatReportPath = Get-LatestCompatReportPath `
                -ReportDir $script:compatReportDir `
                -SinceTimestamp $launchStart `
                -SinceSkewSeconds 10
              if (-not [string]::IsNullOrWhiteSpace($latestCompatReportPath) -and (Test-Path -LiteralPath $latestCompatReportPath)) {
                $compatRaw = Get-Content -LiteralPath $latestCompatReportPath -Raw -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($compatRaw)) {
                  $compatObj = $compatRaw | ConvertFrom-Json -ErrorAction Stop
                  if ($compatObj | Get-Member -Name "items" -MemberType NoteProperty, Property) {
                    foreach ($item in @($compatObj.items)) {
                      if ($null -eq $item) { continue }
                      $status = if ($item | Get-Member -Name "status" -MemberType NoteProperty, Property) { [string]$item.status } else { "" }
                      $modId = if ($item | Get-Member -Name "modId" -MemberType NoteProperty, Property) { [string]$item.modId } else { "" }
                      if ([string]::IsNullOrWhiteSpace($modId)) { continue }
                      if ($status -eq "handled") {
                        $fabricHandledModIds += @($modId)
                      } elseif ($status -eq "unresolved_in_game_mods") {
                        $fabricUnresolvedModIds += @($modId)
                      }
                    }
                  }
                }
              }
            } catch {
              Write-Host ("Warning: failed to read compatibility report for Fabric routing: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }

            $fabricHandledModIds = @($fabricHandledModIds | Sort-Object -Unique)
            $fabricUnresolvedModIds = @($fabricUnresolvedModIds | Sort-Object -Unique)
            if ($fabricHandledModIds.Count -gt 0) {
              Write-Host ("Fabric-guided Baseline Analysis handled mods: {0}" -f ($fabricHandledModIds -join ", ")) -ForegroundColor Gray
            }
            if ($fabricUnresolvedModIds.Count -gt 0) {
              Write-Host ("Fabric-guided Baseline Analysis unresolved mod IDs: {0}" -f ($fabricUnresolvedModIds -join ", ")) -ForegroundColor Yellow
            }
          }

          if ($effectiveIsolateOnNoChanges -and (-not $skipDeepPipelineForFabric)) {
            # * Step 1: Try targeted Mixin analysis before heavy isolation.
            $ranMixinAnalysis = $false
            $mixinResolved = $false
            if ($mixinAnalysisAvailable) {
              Write-Host "Baseline Analysis made no changes. Trying Mixin Analysis." -ForegroundColor Cyan
              $mixinParams = Get-MixinAnalysisParam -LogSinceTimestamp $launchStart
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

              $mixinResultObj = Select-StageResultObject -Result $mixinResult
              if ($null -ne $mixinResultObj -and ($mixinResultObj | Get-Member -Name "Stage" -MemberType NoteProperty, Property) -and $mixinResultObj.Stage -eq "MixinAnalysis") {
                # * Collect Mixin conflict info regardless of resolution outcome.
                if ($mixinResultObj | Get-Member -Name "MixinConflicts" -MemberType NoteProperty, Property) {
                  $conflicts = @($mixinResultObj.MixinConflicts)
                  if ($conflicts.Count -gt 0) {
                    $sessionMixinConflicts = @($conflicts)
                  }
                }

                if ($mixinResultObj.Resolved) {
                  foreach ($move in @($mixinResultObj.CulpritMoves)) {
                    if ($null -eq $move) { continue }
                    $name = [string]$move.JarName
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }
                    $sessionIsolationCulpritByJar[$name.ToLowerInvariant()] = $move
                    $sessionIsolationCulpritHistoryByJar[$name.ToLowerInvariant()] = $move
                  }
                  $mixinResolved = $true
                  Write-Host "Mixin Analysis resolved the crash. Returning to main loop." -ForegroundColor Cyan
                  Start-Sleep -Seconds 2
                  continue
                }
              }
              if (-not $mixinResolved -and $ranMixinAnalysis) {
                Write-Host ("Mixin Analysis did not resolve (exit {0}). Proceeding to Layering." -f $mixinExitCode) -ForegroundColor Gray
              }
            }

            # * Step 2: Try Наслоение (additive strategy), then fall back to subtractive Изоляция.
            $ranLayering = $false
            if ($layeringAvailable) {
              Write-Host "Running Layering strategy." -ForegroundColor Cyan
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

              $layeringResultObj = Select-StageResultObject -Result $layeringResult
              $layerCulpritCount = 0
              $layerSkippedCount = 0
              if ($null -ne $layeringResultObj -and ($layeringResultObj | Get-Member -Name "Stage" -MemberType NoteProperty, Property) -and $layeringResultObj.Stage -eq "Layering") {
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

                $layeringResultObj = Select-StageResultObject -Result $layeringResult
                if ($null -ne $layeringResultObj -and ($layeringResultObj | Get-Member -Name "Stage" -MemberType NoteProperty, Property) -and $layeringResultObj.Stage -eq "Layering") {
                    foreach ($move in @($layeringResultObj.CulpritMoves)) {
                      if ($null -eq $move) { continue }
                      $name = [string]$move.JarName
                      if ([string]::IsNullOrWhiteSpace($name)) { continue }
                      $sessionIsolationCulpritByJar[$name.ToLowerInvariant()] = $move
                      $sessionIsolationCulpritHistoryByJar[$name.ToLowerInvariant()] = $move
                    }
                }
              }

              if ($layerExitCode -eq 0) {
                # * Ensure no game instance survives Наслоение before recovery/main-loop continuation.
                if (-not $DryRun) {
                  $closedAfterLayering = Stop-GameProcess -Names $GameProcessNames -StartedAfter $sessionStartTime
                  if ($closedAfterLayering -gt 0) {
                    Write-Host ("Closed {0} running game process(es) before post-Layering actions." -f $closedAfterLayering) -ForegroundColor Gray
                  }
                }

                # * Step 3: Recovery — try to restore phantom culprits.
                if ($recoveryAvailable -and $sessionIsolationCulpritHistoryByJar.Count -ge 3) {
                  Write-Host "Running Recovery analysis." -ForegroundColor Cyan
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
                    $recObj = Select-StageResultObject -Result $recResult
                    if ($null -ne $recObj -and ($recObj | Get-Member -Name "Stage" -MemberType NoteProperty, Property) -and $recObj.Stage -eq "Recovery") {
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
                    Write-Host ("Warning: Recovery failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                  }
                }
                Write-Host "Layering completed. Returning to main loop." -ForegroundColor Cyan
                Start-Sleep -Seconds 2
                continue
              }
              if ($layerExitCode -eq 130) {
                $sessionInterrupted = $true
                Write-Host "Launcher start canceled by user during Layering. Stopping by user choice." -ForegroundColor Yellow
                Invoke-PostSessionOutcomeDialogCleanup
                exit 0
              }
              Write-Host ("Layering finished with exit code {0}. Falling back to Isolation." -f $layerExitCode) -ForegroundColor Yellow
            }

            if ($stageLayeringEnabled -and (-not $ranLayering -or $layerExitCode -ne 0)) {
              if ($ranLayering -and $layerExitCode -ne 0) {
                $script:suppressTranscriptCulpritInference = $true
              }
              if ($ranLayering -and $layerExitCode -ne 0 -and $null -ne $layeringResultObj -and ($layeringResultObj | Get-Member -Name "Stage" -MemberType NoteProperty, Property) -and $layeringResultObj.Stage -eq "Layering") {
                $tentativeLayerMoves = @($layeringResultObj.CulpritMoves | Where-Object { $null -ne $_ })
                if ($tentativeLayerMoves.Count -gt 0) {
                  $script:suppressTranscriptCulpritInference = $true
                  Write-Host "Layering did not complete successfully. Restoring tentative Layering culprits before fallback Isolation." -ForegroundColor Yellow
                  $tentativeLayerNameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                  foreach ($tentativeMove in $tentativeLayerMoves) {
                    if ($null -eq $tentativeMove) { continue }
                    $tentativeJarName = [string]$tentativeMove.JarName
                    if ([string]::IsNullOrWhiteSpace($tentativeJarName)) { continue }
                    $null = $tentativeLayerNameSet.Add($tentativeJarName)
                  }
                  $restoreLayeringInfo = Restore-IsolationCulpritMod -CulpritMoves $tentativeLayerMoves -ReturnDetails
                  $restoredTentativeNames = @($restoreLayeringInfo.RestoredJarNames)
                  $failedTentativeNames = @($restoreLayeringInfo.FailedJarNames)

                  foreach ($name in @($tentativeLayerNameSet)) {
                    $jarName = [string]$name
                    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
                    $nameKey = $jarName.ToLowerInvariant()
                    $null = $sessionIsolationCulpritByJar.Remove($nameKey)
                    $null = $sessionIsolationCulpritHistoryByJar.Remove($nameKey)
                  }

                  if ($restoredTentativeNames.Count -gt 0) {
                    Write-Host ("Restored {0} tentative Layering culprit(s) before fallback Isolation." -f $restoredTentativeNames.Count) -ForegroundColor Gray
                  }
                  if ($failedTentativeNames.Count -gt 0) {
                    $failedPreview = @($failedTentativeNames | Select-Object -First 10)
                    $failedSuffix = if ($failedTentativeNames.Count -gt $failedPreview.Count) { " (+{0} more)" -f ($failedTentativeNames.Count - $failedPreview.Count) } else { "" }
                    Write-Host ("Warning: failed to restore tentative Layering culprits: {0}{1}" -f ($failedPreview -join ", "), $failedSuffix) -ForegroundColor Yellow
                    Write-Host "Tentative Layering culprits were removed from session report despite restore failures." -ForegroundColor Yellow
                  }

                  if (-not [bool]$restoreLayeringInfo.Success) {
                    Write-Host "Warning: failed to restore one or more tentative Layering culprits before fallback Isolation." -ForegroundColor Yellow
                  }
                }
              }
              Write-Host "Running subtractive Isolation." -ForegroundColor Cyan
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
                Write-Host ("Warning: Isolation failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                $isolateExitCode = 1
              }

              $isolationResultObj = Select-StageResultObject -Result $isolationResult
              $isolateSkippedCount = 0
              $isolateCulpritCount = 0
              if ($null -ne $isolationResultObj -and ($isolationResultObj | Get-Member -Name "Stage" -MemberType NoteProperty, Property) -and $isolationResultObj.Stage -eq "Isolation") {
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
                  Write-Host ("Warning: Isolation retry failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                  $isolateExitCode = 1
                }

                $isolationResultObj = Select-StageResultObject -Result $isolationResult
                if ($null -ne $isolationResultObj -and ($isolationResultObj | Get-Member -Name "Stage" -MemberType NoteProperty, Property) -and $isolationResultObj.Stage -eq "Isolation") {
                    $sessionIsolationFastForwardJarNames = @($isolationResultObj.FastForwardJarNames)
                    $sessionIsolationFastForwardEvidenceKey = [string]$isolationResultObj.BaselineEvidenceKey
                    foreach ($move in @($isolationResultObj.CulpritMoves)) {
                      if ($null -eq $move) { continue }
                      $name = [string]$move.JarName
                      if ([string]::IsNullOrWhiteSpace($name)) { continue }
                      $sessionIsolationCulpritByJar[$name.ToLowerInvariant()] = $move
                      $sessionIsolationCulpritHistoryByJar[$name.ToLowerInvariant()] = $move
                    }
                }
              }

              if ($isolateExitCode -eq 130) {
                $sessionInterrupted = $true
                Write-Host "Launcher start canceled by user during Isolation. Stopping by user choice." -ForegroundColor Yellow
                Invoke-PostSessionOutcomeDialogCleanup
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
          if ($skipDeepPipelineForFabric) {
            Write-Host "Baseline Analysis made no changes in Fabric-guided mode. Skipping Mixin Analysis/Layering for this attempt." -ForegroundColor Yellow
            $compatExitCode = 0
          } else {
            Write-Host "Baseline Analysis made no changes. Stopping to avoid a loop." -ForegroundColor Yellow
            exit 3
          }
        }
        Write-Host ("Baseline Analysis failed with exit code {0}. Stopping." -f $compatExitCode) -ForegroundColor Red
        exit $compatExitCode
      }
    } else {
      $compatParams = Get-CompatibilityParam -LogSinceTimestamp $launchStart
      $compatExtraArgs = Get-CompatibilityExtraArg
      $prettyCompatParams = Format-IsolationParamsForDisplay -Params $compatParams
      if ($prettyCompatParams.Count -gt 0 -and $compatExtraArgs.Count -gt 0) {
        Write-Host ("DRYRUN would run: {0} {1} {2}" -f $CheckScriptPath, ($prettyCompatParams -join " "), ($compatExtraArgs -join " ")) -ForegroundColor Gray
      } elseif ($prettyCompatParams.Count -gt 0) {
        Write-Host ("DRYRUN would run: {0} {1}" -f $CheckScriptPath, ($prettyCompatParams -join " ")) -ForegroundColor Gray
      } elseif ($compatExtraArgs.Count -gt 0) {
        Write-Host ("DRYRUN would run: {0} {1}" -f $CheckScriptPath, ($compatExtraArgs -join " ")) -ForegroundColor Gray
      } else {
        Write-Host ("DRYRUN would run: {0}" -f $CheckScriptPath) -ForegroundColor Gray
      }
      if ($effectiveIsolateOnNoChanges -and $stageLayeringEnabled) {
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
      if ($DryRun) {
        Write-Host "DRYRUN would close crash/fabric outcome dialogs." -ForegroundColor Gray
      } else {
        $lastCrashDialogHandleId = Close-OutcomeWindowWithExtraDialog -Outcome $outcome `
          -DelaySeconds $CrashCloseDelaySeconds `
          -OffsetX $CrashCloseClickOffsetX `
          -OffsetY $CrashCloseClickOffsetY `
          -CloseExtraFabricDialogs $true
      }
    }

    # * Wait before retrying after a crash.
    Write-Host "Waiting 5 seconds before retry..." -ForegroundColor Cyan
    Start-Sleep -Seconds 5
    continue
  }

  if ($outcome.Type -eq "FabricDialog") {
    Write-Host "Outcome: Fabric Loader dialog detected." -ForegroundColor Yellow
    if ($null -ne $outcome.Window) {
      if ($DryRun) {
        Write-Host "DRYRUN would close Fabric Loader dialog." -ForegroundColor Gray
      } elseif ($fabricMissingDepsDetected) {
        [void](Close-OutcomeWindowWithExtraDialog -Outcome $outcome `
            -DelaySeconds 0 `
            -OffsetX $CrashCloseClickOffsetX `
            -OffsetY $CrashCloseClickOffsetY `
            -CloseExtraFabricDialogs $true)
      } else {
        [void](Close-OutcomeWindowWithExtraDialog -Outcome $outcome `
            -DelaySeconds 0 `
            -OffsetX $CrashCloseClickOffsetX `
            -OffsetY $CrashCloseClickOffsetY `
            -CloseExtraFabricDialogs $true)
      }
    }
  } elseif ($outcome.Type -eq "NoLaunch") {
    Write-Host ("Outcome: no game launch detected within {0} seconds." -f $SuccessGraceSeconds) -ForegroundColor Yellow
  } elseif ($outcome.Type -eq "ProcessExit") {
    Write-Host "Outcome: game process exited without crash/fabric dialog." -ForegroundColor Green
  } else {
    Write-Host ("Outcome: no crash/fabric dialog detected within {0} seconds." -f $OutcomeTimeoutSeconds) -ForegroundColor Green
  }

  if ($outcome.Type -eq "FabricDialog" -and $AutoHandleFabricDialog -and $DryRun) {
    Write-Host "DRYRUN would try to auto-handle the Fabric dialog." -ForegroundColor Gray
  }
  if (-not $DryRun) {
    if ($outcome.Type -eq "Timeout") {
      Write-Host "No crash detected after clean launch; closing game before prompt so the terminal menu is visible." -ForegroundColor Gray
    }
    $closedAfterNonCrashOutcome = Stop-GameProcess -Names $GameProcessNames -StartedAfter $sessionStartTime
    if ($closedAfterNonCrashOutcome -gt 0) {
      Write-Host ("Closed {0} running game process(es) before prompt." -f $closedAfterNonCrashOutcome) -ForegroundColor Gray
    }
    [void](Wait-ConfiguredGameExit -StartedAfter $sessionStartTime -WarningContext "terminal decision prompt")
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
  if ($outcome.Type -eq "FabricDialog" -and $fabricMissingDepsDetected) {
    if ($hasSessionIsolants) {
      Write-Host "Restoring isolated mods before exit..." -ForegroundColor Cyan
      $ok = Restore-IsolationCulpritMod -CulpritMoves @($sessionIsolationCulpritByJar.Values)
      if (-not $ok) {
        Write-Host "Warning: some isolated mods could not be restored automatically. Please review Legacy folders." -ForegroundColor Yellow
        exit 1
      }
      $sessionIsolationCulpritByJar = @{}
    }
    $missLabel = if ($fabricMissingDepIds.Count -gt 0) { $fabricMissingDepIds -join ", " } else { "<none>" }
    $reqLabel = if ($fabricRequiringModIds.Count -gt 0) { $fabricRequiringModIds -join ", " } else { "<none>" }
    Write-Host ("Fabric dialog shows missing dependencies: {0}. User action is required." -f $missLabel) -ForegroundColor Yellow
    Write-Host ("Requiring mods: {0}" -f $reqLabel) -ForegroundColor Gray
    Invoke-PostSessionOutcomeDialogCleanup
    exit 0
  }
  $cleanOutcome = ($outcome.Type -eq "Timeout" -or $outcome.Type -eq "ProcessExit")
  if ($cleanOutcome -and $hasSessionIsolants -and $recoveryAvailable) {
    if (-not $DryRun) {
      $closedBeforeRecovery = Stop-GameProcess -Names $GameProcessNames -StartedAfter $sessionStartTime
      if ($closedBeforeRecovery -gt 0) {
        Write-Host ("Closed {0} running game process(es) before Recovery." -f $closedBeforeRecovery) -ForegroundColor Gray
      }
      [void](Wait-ConfiguredGameExit -StartedAfter $sessionStartTime -WarningContext "Recovery analysis")
    }

    Write-Host "Running Recovery analysis." -ForegroundColor Cyan
    try {
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

      $recResult = & $RecoveryScriptPath @recParams
      $recObj = Select-StageResultObject -Result $recResult
      if ($null -ne $recObj -and ($recObj | Get-Member -Name "Stage" -MemberType NoteProperty, Property) -and $recObj.Stage -eq "Recovery") {
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
      Write-Host ("Warning: Recovery failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

    $hasSessionIsolants = $sessionIsolationCulpritByJar.Count -gt 0
  }

  if ($cleanOutcome -and (-not $hasSessionIsolants)) {
    Write-Host "No blocking errors and no isolated mods pending. Continuing automatically." -ForegroundColor Cyan
    Invoke-PostSessionOutcomeDialogCleanup
    exit 0
  }

  $requiresUserDecision = $hasSessionIsolants -or ($outcome.Type -eq "FabricDialog") -or ($outcome.Type -eq "NoLaunch")
  if (-not $requiresUserDecision) {
    Write-Host "No blocking errors and no isolated mods pending. Continuing automatically." -ForegroundColor Cyan
    Invoke-PostSessionOutcomeDialogCleanup
    exit 0
  }

  $prompt = $null
  if ($outcome.Type -eq "NoLaunch") {
    $prompt = $(if ($hasSessionIsolants) { "Game launch not detected. Choose action for isolated mods:" } else { "Game launch not detected. Continue retrying? (<KEY_RETRY_HINT>)" })
  } elseif ($outcome.Type -eq "FabricDialog") {
    $prompt = $(if ($hasSessionIsolants) { "Fabric Loader window detected (incompatibility/dependencies). Choose action for isolated mods:" } else { "Fabric Loader window detected (incompatibility/dependencies). Continue retrying? (<KEY_RETRY_HINT>)" })
  } elseif ($cleanOutcome) {
    $prompt = $(if ($hasSessionIsolants) { "No crash detected. Choose action for isolated mods:" } else { "No crash detected. It seems there are no problematic mods. Continue retrying? (<KEY_RETRY_HINT>)" })
  } else {
    $prompt = $(if ($hasSessionIsolants) { "No crash detected. Choose action for isolated mods:" } else { "No crash detected. Continue retrying? (<KEY_RETRY_HINT>)" })
  }

  if ($hasSessionIsolants) {
    Write-Host $prompt -ForegroundColor Yellow
    Write-Host "Why this prompt appears: previous attempts isolated one or more mods into Legacy to test stability." -ForegroundColor Gray
    Write-Host "Choose final action: run Recovery, rollback isolated mods, or accept current isolated mods and stop." -ForegroundColor Gray
    Write-Host "  <KEY_CONTINUE_AS_IS> = run Recovery analysis and stop." -ForegroundColor Gray
    Write-Host "  <KEY_RESTORE_EXIT> = rollback changes (restore isolated mods) and stop." -ForegroundColor Gray
    Write-Host "  <KEY_KEEP_EXIT> = accept current isolated mods and stop." -ForegroundColor Gray

    $choice = ""
    while ([string]::IsNullOrWhiteSpace($choice)) {
      $answerRaw = [string](Read-Host "Choice [<KEY_ISOLANTS_HINT>]")
      $answer = $answerRaw.Trim().ToLowerInvariant()
      if ($answer -match $regexChoiceRunRecovery) {
        $choice = "run-recovery-and-exit"
        break
      }
      if ($answer -match $regexChoiceRollbackExit) {
        $choice = "rollback-and-exit"
        break
      }
      if ($answer -match $regexChoiceAcceptExit) {
        $choice = "accept-and-exit"
        break
      }
      Write-Host "Invalid input. Enter <KEY_CONTINUE_AS_IS>, <KEY_RESTORE_EXIT>, or <KEY_KEEP_EXIT>." -ForegroundColor Yellow
    }

    if ($choice -eq "accept-and-exit") {
      Write-Host "Recovery skipped by user choice. Current isolated mods are kept as incompatible." -ForegroundColor Yellow
      Write-Host "Stopping by user choice." -ForegroundColor Yellow
      Invoke-PostSessionOutcomeDialogCleanup
      exit 0
    }

    # * User selected rollback; restore all currently isolated mods and stop.
    if ($choice -eq "rollback-and-exit") {
      if (-not $DryRun) {
        $closedBeforeRestore = Stop-GameProcess -Names $GameProcessNames -StartedAfter $sessionStartTime
        if ($closedBeforeRestore -gt 0) {
          Write-Host ("Closed {0} running game process(es) before restore." -f $closedBeforeRestore) -ForegroundColor Gray
        }
        [void](Wait-ConfiguredGameExit -StartedAfter $sessionStartTime -WarningContext "restore isolated mods")
      }

      Write-Host "Restoring isolated mods before exit..." -ForegroundColor Cyan
      $ok = Restore-IsolationCulpritMod -CulpritMoves @($sessionIsolationCulpritByJar.Values)
      if (-not $ok) {
        Write-Host "Warning: some isolated mods could not be restored automatically. Please review Legacy folders." -ForegroundColor Yellow
        exit 1
      }
      $sessionIsolationCulpritByJar = @{}
      Write-Host "Stopping by user choice." -ForegroundColor Yellow
      Invoke-PostSessionOutcomeDialogCleanup
      exit 0
    }

    # * Recovery mode: run Recovery stage once and stop.
    if (-not $recoveryAvailable) {
      Write-Host "Recovery stage disabled in config ([Stages].EnableRecovery=false)." -ForegroundColor Yellow
      Write-Host "Stopping by user choice." -ForegroundColor Yellow
      Invoke-PostSessionOutcomeDialogCleanup
      exit 0
    }

    if (-not $DryRun) {
      $closedBeforeRecovery = Stop-GameProcess -Names $GameProcessNames -StartedAfter $sessionStartTime
      if ($closedBeforeRecovery -gt 0) {
        Write-Host ("Closed {0} running game process(es) before Recovery." -f $closedBeforeRecovery) -ForegroundColor Gray
      }
      [void](Wait-ConfiguredGameExit -StartedAfter $sessionStartTime -WarningContext "Recovery analysis")
    }

    Write-Host "Running Recovery analysis." -ForegroundColor Cyan
    try {
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

      $recResult = & $RecoveryScriptPath @recParams
      $recObj = Select-StageResultObject -Result $recResult
      if ($null -ne $recObj -and ($recObj | Get-Member -Name "Stage" -MemberType NoteProperty, Property) -and $recObj.Stage -eq "Recovery") {
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
      Write-Host ("Warning: Recovery failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
      exit 1
    }
    Write-Host "Stopping by user choice." -ForegroundColor Yellow
    Invoke-PostSessionOutcomeDialogCleanup
    exit 0
  }

  $answer = Read-Host $prompt
  if ($answer -notmatch $regexRetryYes) {
    if ($hasSessionIsolants) {
      Write-Host "Restoring isolated mods before exit..." -ForegroundColor Cyan
      $ok = Restore-IsolationCulpritMod -CulpritMoves @($sessionIsolationCulpritByJar.Values)
      if (-not $ok) {
        Write-Host "Warning: some isolated mods could not be restored automatically. Please review Legacy folders." -ForegroundColor Yellow
        exit 1
      }
      $sessionIsolationCulpritByJar = @{}
    }
    Write-Host "If the script did not resolve the issue or broke on specific mods and dependencies, isolate those toxic mods manually while the script runs." -ForegroundColor Yellow
    Write-Host "Stopping by user choice." -ForegroundColor Yellow
    Invoke-PostSessionOutcomeDialogCleanup
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
