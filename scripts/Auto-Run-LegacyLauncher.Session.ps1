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
  if ($lastCrashDialogHandleId -ne 0 -and (Test-WindowPresence -HandleId $lastCrashDialogHandleId)) {
    $ignoreCrashIds = @($lastCrashDialogHandleId)
  } else {
    $lastCrashDialogHandleId = 0
  }
  $outcome = Wait-ForOutcome -CrashPatterns $CrashWindowTitlePatterns `
    -FabricPatterns $FabricWindowTitlePatterns `
    -TimeoutSeconds $OutcomeTimeoutSeconds `
    -PollSeconds $PollIntervalSeconds `
    -LaunchStart $launchStart `
    -GameProcessNames $GameProcessNames `
    -LauncherHandleId ([long]$launcherWindow.Handle.ToInt64()) `
    -LaunchStartTimeoutSeconds $SuccessGraceSeconds `
    -RequireGameStartForTimeout ([bool]($SuccessGraceSeconds -gt 0)) `
    -IgnoreHandleIds $ignoreCrashIds

  # * Race guard: a crash/fabric dialog can appear right after Wait-ForOutcome returns.
  # * Re-check for a short grace window before branching into outcome handling.
  if ($outcome.Type -eq "Timeout") {
    $lateDeadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $lateDeadline -and $outcome.Type -eq "Timeout") {
      $lateCrashNow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns -ExcludeHandleIds $ignoreCrashIds
      if ($null -ne $lateCrashNow) {
        Write-Host ("Late crash dialog detected after probe window: {0}" -f $lateCrashNow.Title) -ForegroundColor Yellow
        $outcome = [pscustomobject]@{ Type = "CrashDialog"; Window = $lateCrashNow }
        break
      }
      $lateFabricNow = Select-WindowByTitlePattern -Patterns $FabricWindowTitlePatterns
      if ($null -ne $lateFabricNow) {
        Write-Host ("Late Fabric dialog detected after probe window: {0}" -f $lateFabricNow.Title) -ForegroundColor Yellow
        $outcome = [pscustomobject]@{ Type = "FabricDialog"; Window = $lateFabricNow }
        break
      }
      Start-Sleep -Milliseconds 300
    }
  }

  if ($outcome.Type -eq "CrashDialog") {
    Write-Host "Outcome: crash dialog detected. Running compatibility cleanup." -ForegroundColor Yellow

    # * Ensure the game is fully closed before any mod file operations.
    # * Without this, layering/isolation can hit file locks in initial quarantine.
    if (-not $DryRun) {
      $closedBeforeCleanup = Stop-GameProcess -Names $GameProcessNames -StartedAfter $sessionStartTime
      if ($closedBeforeCleanup -gt 0) {
        Write-Host ("Closed {0} running game process(es) before cleanup." -f $closedBeforeCleanup) -ForegroundColor Gray
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
      if ($compatExitCode -ne 0) {
        if ($compatExitCode -eq 3) {
          if ($effectiveIsolateOnNoChanges) {
            # * Step 1: Try targeted Mixin analysis before heavy isolation.
            $ranMixinAnalysis = $false
            $mixinResolved = $false
            if ($mixinAnalysisAvailable) {
              Write-Host "Compatibility cleanup made no changes. Trying Mixin error analysis." -ForegroundColor Cyan
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
                # * Ensure no game instance survives layering before recovery/main-loop continuation.
                if (-not $DryRun) {
                  $closedAfterLayering = Stop-GameProcess -Names $GameProcessNames -StartedAfter $sessionStartTime
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

            if ($stageLayeringEnabled -and (-not $ranLayering -or $layerExitCode -ne 0)) {
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
                  Write-Host ("Warning: isolation retry failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
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
  if (-not $DryRun) {
    $closedAfterNonCrashOutcome = Stop-GameProcess -Names $GameProcessNames -StartedAfter $sessionStartTime
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
  $cleanOutcome = ($outcome.Type -eq "Timeout" -or $outcome.Type -eq "ProcessExit")
  $requiresUserDecision = $hasSessionIsolants -or ($outcome.Type -eq "FabricDialog") -or ($outcome.Type -eq "NoLaunch") -or $cleanOutcome
  if (-not $requiresUserDecision) {
    Write-Host "No blocking errors and no isolated mods pending. Continuing automatically." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    continue
  }

  $prompt = $null
  if ($outcome.Type -eq "NoLaunch") {
    $prompt = $(if ($hasSessionIsolants) { "Запуск игры не обнаружен. Выберите действие для изолированных модов:" } else { "Запуск игры не обнаружен. Продолжить попытки? (y/n)" })
  } elseif ($outcome.Type -eq "FabricDialog") {
    $prompt = $(if ($hasSessionIsolants) { "Обнаружено окно Fabric Loader (несовместимость/зависимости). Выберите действие для изолированных модов:" } else { "Обнаружено окно Fabric Loader (несовместимость/зависимости). Продолжить попытки? (y/n)" })
  } elseif ($cleanOutcome) {
    $prompt = $(if ($hasSessionIsolants) { "Краш не обнаружен. Выберите действие для изолированных модов:" } else { "Краш не обнаружен. Похоже, проблемных модов нет. Продолжить попытки? (y/n)" })
  } else {
    $prompt = $(if ($hasSessionIsolants) { "Краш не обнаружен. Выберите действие для изолированных модов:" } else { "Краш не обнаружен. Продолжить попытки? (y/n)" })
  }

  if ($hasSessionIsolants) {
    Write-Host $prompt -ForegroundColor Yellow
    Write-Host "  c = продолжить с текущими изолятами (неполный набор модов)." -ForegroundColor Gray
    Write-Host "  r = вернуть изоляты и продолжить с полного набора." -ForegroundColor Gray
    Write-Host "  n = вернуть изоляты и завершить." -ForegroundColor Gray
    Write-Host "  s = пропустить Recovery и завершить (оставить текущие изоляты как несовместимые)." -ForegroundColor Gray

    $choice = ""
    while ([string]::IsNullOrWhiteSpace($choice)) {
      $answerRaw = [string](Read-Host "Выбор [c/r/n/s]")
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
      if ($answer -match "^(s|skip|stop|з|завершить)$") {
        $choice = "keep-and-exit"
        break
      }
      Write-Host "Неверный ввод. Введите c, r, n или s." -ForegroundColor Yellow
    }

    if ($choice -eq "continue-as-is") {
      Write-Host "Продолжаю попытки без деизолирования модов." -ForegroundColor Cyan
      Start-Sleep -Seconds 1
      continue
    }

    if ($choice -eq "keep-and-exit") {
      Write-Host "Recovery пропущен по выбору пользователя. Текущие изоляты оставлены как несовместимые." -ForegroundColor Yellow
      Write-Host "Stopping by user choice." -ForegroundColor Yellow
      exit 0
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
