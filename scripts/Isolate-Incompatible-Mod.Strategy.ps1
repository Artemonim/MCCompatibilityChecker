if ($null -eq $isolationStageResults -or -not ($isolationStageResults -is [hashtable])) {
  $isolationStageResults = @{}
}
$strategyStageResult = New-McccStageAccumulator -Stage "Isolation.Strategy"

  if (-not $skipIsolation) {
    if ($effectiveIsolationStrategy -eq "Hybrid") {
      $hybridResult = Invoke-HybridIsolation -Mods $candidateMods `
        -BaselineSignature $baselineSignature `
        -BaselineEvidenceKey $baselineEvidenceKey
      if ($hybridResult.Found) {
        $culpritJarNames = @($hybridResult.CulpritJarNames)
        $stopReason = $hybridResult.StopReason
      }
    } else {

      $didExponential = $false
      if ($effectiveIsolationStrategy -eq "Exponential") {
        $exponentialCandidates = @($candidateMods | Where-Object { -not $pinnedJarNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
        if ($exponentialCandidates.Count -gt 0) {
          Write-Host ("Exponential Isolation enabled. Candidates: {0}" -f $exponentialCandidates.Count) -ForegroundColor Gray
        } else {
          Write-Host "Exponential Isolation enabled, but no candidates remain after pinned exclusions." -ForegroundColor Yellow
        }
        if ($exponentialCandidates.Count -gt 0) {
          $exponentialResult = Invoke-ExponentialIsolation -Mods $exponentialCandidates `
            -BaselineSignature $baselineSignature `
            -BaselineEvidenceKey $baselineEvidenceKey `
            -PinnedJarNames $pinnedJarNames
          $didExponential = $true
          $candidateMods = @($exponentialResult.Remaining)
          Write-Host ("Exponential Isolation completed. Switching to linear with {0} mod(s) ({1})." -f $candidateMods.Count, $exponentialResult.Reason) -ForegroundColor Gray
        }
      }

      if ($didExponential -and (-not $baselineSucceeded) -and $candidateMods -and $candidateMods.Count -gt 0) {
        # * Exponential/binary probing can quick-isolate additional mods (dependencies/requirers),
        # * which can change the observed error signature. Refresh baseline before the linear phase
        # * to avoid falsely blaming a stable mod as "error_changed" relative to the original baseline.
        Write-Host "Refreshing baseline signature for linear phase." -ForegroundColor Gray

        $linearBaselineAttemptStart = Get-Date
        $phase = "linear_phase_baseline_invoke_launch"
        $linearBaselineOutcomeObj = Invoke-ConfiguredLaunchAttempt -IgnoreHandleIds @()

        $linearBaselineOutcome = $linearBaselineOutcomeObj.Type
        Write-Host ("Linear phase baseline outcome: {0}" -f $linearBaselineOutcome) -ForegroundColor $(if ($linearBaselineOutcome -eq "Timeout") { "Green" } else { "Yellow" })

        if ($linearBaselineOutcome -ne "Timeout") {
          if ($null -ne $linearBaselineOutcomeObj.Window) {
            $phase = "linear_phase_baseline_close_outcome_window"
            $script:lastOutcomeHandleId = Close-OutcomeWindowWithExtraDialog -Outcome $linearBaselineOutcomeObj `
              -DelaySeconds $CrashCloseDelaySeconds `
              -OffsetX $CrashCloseClickOffsetX `
              -OffsetY $CrashCloseClickOffsetY `
              -CloseExtraFabricDialogs $false
          }
          $phase = "linear_phase_baseline_wait_game_exit"
          [void](Wait-ConfiguredGameExit -StartedAfter $linearBaselineAttemptStart)
        } else {
          # ! If the baseline issue does not reproduce at phase entry, isolation results are unreliable.
          # ! Stop early to prevent moving a random mod to Legacy.
          $linearBaselineNotReproducedWarning = "Warning: baseline issue not reproduced in linear phase. Stopping Isolation to avoid false culprit selection."
          Write-Host $linearBaselineNotReproducedWarning -ForegroundColor Yellow
          Add-McccStageWarning `
            -Accumulator $strategyStageResult `
            -Category "linear_phase" `
            -Code "BASELINE_NOT_REPRODUCED_LINEAR_PHASE" `
            -Message $linearBaselineNotReproducedWarning `
            -Context @{
            LinearBaselineOutcome = $linearBaselineOutcome
            CandidateCount = [int]@($candidateMods).Count
          } | Out-Null
          $candidateMods = @()
        }

        Wait-ConfiguredLauncherInteractive

        if ($candidateMods -and $candidateMods.Count -gt 0 -and $linearBaselineOutcome -ne "Timeout") {
          Start-Sleep -Seconds $LogPostRunDelaySeconds
          $phase = "linear_phase_baseline_read_logs"
          $linearBaselineSnapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $linearBaselineAttemptStart
          if (Test-DependencyDialogBlock -Context "linear phase baseline" -Lines $linearBaselineSnapshot.Lines) {
            $stopReason = "dependency_dialog_linear_baseline"
            Add-McccStageWarning `
              -Accumulator $strategyStageResult `
              -Category "dependency_dialog" `
              -Code "DEPENDENCY_DIALOG_LINEAR_BASELINE" `
              -Message "Isolation stopped due to dependency dialog in linear phase baseline." `
              -Context @{
              Context = "linear phase baseline"
              CandidateCount = [int]@($candidateMods).Count
            } | Out-Null
            $candidateMods = @()
          }
          $activeBaselineSignature = Get-ErrorSignature -Lines $linearBaselineSnapshot.Lines `
            -MaxLines $ErrorSignatureLineLimit `
            -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
          $script:activeBaselineEvidenceKey = Get-ErrorEvidenceKey -Lines $linearBaselineSnapshot.Lines -MaxLines $ErrorSignatureLineLimit
          if ([string]::IsNullOrWhiteSpace($activeBaselineSignature)) {
            Write-Host "Linear phase baseline signature is empty. Error change detection may be limited." -ForegroundColor Yellow
            Add-McccStageWarning `
              -Accumulator $strategyStageResult `
              -Category "baseline_signature" `
              -Code "LINEAR_BASELINE_SIGNATURE_EMPTY" `
              -Message "Linear phase baseline signature is empty. Error change detection may be limited." `
              -Context @{
              BaselineEvidenceKey = $script:activeBaselineEvidenceKey
              CandidateCount = [int]@($candidateMods).Count
            } | Out-Null
          } else {
            Write-Verbose ("Linear phase baseline signature: {0}" -f $activeBaselineSignature)
          }
        }
      }

      $linearResult = Invoke-LinearIsolation -Mods $candidateMods
      if ($linearResult.Found) {
        $culpritJarNames = @($linearResult.CulpritJarNames)
        $stopReason = $linearResult.StopReason
      }
    }
  }

Set-McccStageResult -StageResults $isolationStageResults -StageResult (Complete-McccStageAccumulator `
    -Accumulator $strategyStageResult `
    -ExtraFields @{
    SkipIsolation = [bool]$skipIsolation
    CulpritCount = [int]@($culpritJarNames).Count
    StopReason = $stopReason
    RemainingCandidateCount = [int]@($candidateMods).Count
  })
