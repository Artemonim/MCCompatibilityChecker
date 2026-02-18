if ($null -eq $isolationStageResults -or -not ($isolationStageResults -is [hashtable])) {
  $isolationStageResults = @{}
}
$baselineStageResult = New-McccStageAccumulator -Stage "Isolation.Baseline"

  if (-not $SkipBaselineRun) {
    Write-Host "Baseline attempt starting." -ForegroundColor Cyan
    $baselineAttemptStart = Get-Date
    $phase = "baseline_invoke_launch"
    $baselineOutcomeObj = Invoke-ConfiguredLaunchAttempt -IgnoreHandleIds @()

    $baselineOutcome = $baselineOutcomeObj.Type
    Write-Host ("Baseline outcome: {0}" -f $baselineOutcome) -ForegroundColor $(if ($baselineOutcome -eq "Timeout") { "Green" } else { "Yellow" })
    if ($baselineOutcome -ne "Timeout") {
      if ($null -ne $baselineOutcomeObj.Window) {
        $phase = "baseline_close_outcome_window"
        $script:lastOutcomeHandleId = Close-OutcomeWindowWithExtraDialog -Outcome $baselineOutcomeObj `
          -DelaySeconds $CrashCloseDelaySeconds `
          -OffsetX $CrashCloseClickOffsetX `
          -OffsetY $CrashCloseClickOffsetY `
          -CloseExtraFabricDialogs $false
      }
      $phase = "baseline_wait_game_exit"
      [void](Wait-ConfiguredGameExit -StartedAfter $baselineAttemptStart -WarningContext "File moves")
    } else {
      $baselineSucceeded = $true
    }
  }

  if (-not $baselineSucceeded) {
    Start-Sleep -Seconds $LogPostRunDelaySeconds
    $phase = "baseline_read_logs"
    $baselineSnapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $baselineAttemptStart

    if (Test-DependencyDialogBlock -Context "baseline" -Lines $baselineSnapshot.Lines) {
      $stopReason = "dependency_dialog_baseline"
      $skipIsolation = $true
      Add-McccStageWarning `
        -Accumulator $baselineStageResult `
        -Category "dependency_dialog" `
        -Code "DEPENDENCY_DIALOG_BASELINE" `
        -Message "Isolation stopped due to dependency dialog in baseline." `
        -Context @{
        Context = "baseline"
        BaselineOutcome = $baselineOutcome
      } | Out-Null
    }

    $mcVersionForLegacy = Get-MinecraftVersionFromLog -Lines $baselineSnapshot.Lines

    $baselineSignature = Get-ErrorSignature -Lines $baselineSnapshot.Lines `
      -MaxLines $ErrorSignatureLineLimit `
      -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
    $baselineEvidenceKey = Get-ErrorEvidenceKey -Lines $baselineSnapshot.Lines -MaxLines $ErrorSignatureLineLimit
    $activeBaselineSignature = $baselineSignature
    $script:activeBaselineEvidenceKey = $baselineEvidenceKey

    if ([string]::IsNullOrWhiteSpace($baselineSignature)) {
      Write-Host "Baseline signature is empty. Error change detection may be limited." -ForegroundColor Yellow
      Add-McccStageWarning `
        -Accumulator $baselineStageResult `
        -Category "baseline_signature" `
        -Code "BASELINE_SIGNATURE_EMPTY" `
        -Message "Baseline signature is empty. Error change detection may be limited." `
        -Context @{
        BaselineOutcome = $baselineOutcome
        BaselineEvidenceKey = $baselineEvidenceKey
      } | Out-Null
    } else {
      Write-Verbose ("Baseline signature: {0}" -f $baselineSignature)
    }

    $pinnedJarNameSet = @{}

    if (-not $skipIsolation -and $PreIsolateJarNames -and $PreIsolateJarNames.Count -gt 0) {
      $preSelection = Get-PreIsolateSelection `
        -PreIsolateJarNames $PreIsolateJarNames `
        -PreviousBaselineEvidenceKey $PreIsolateBaselineEvidenceKey `
        -CurrentBaselineEvidenceKey $baselineEvidenceKey
      if ($preSelection.EvidenceMismatch) {
        Write-Host "Fast-forward disabled: baseline evidence changed." -ForegroundColor Gray
        Add-McccStageWarning `
          -Accumulator $baselineStageResult `
          -Category "fast_forward" `
          -Code "FAST_FORWARD_BASELINE_MISMATCH" `
          -Message "Fast-forward disabled: baseline evidence changed." `
          -Context @{
          PreviousBaselineEvidenceKey = $PreIsolateBaselineEvidenceKey
          CurrentBaselineEvidenceKey = $baselineEvidenceKey
          RequestedPreIsolateCount = [int]@($PreIsolateJarNames).Count
        } | Out-Null
        Write-Verbose ("Previous baseline evidence: {0}" -f $PreIsolateBaselineEvidenceKey)
        Write-Verbose ("Current baseline evidence: {0}" -f $baselineEvidenceKey)
        $PreIsolateJarNames = @()
      }
      $preList = @($preSelection.JarNames)
      if ($preList.Count -gt 0) {
        $existingJarNames = New-Object System.Collections.Generic.List[string]
        foreach ($jarName in $preList) {
          if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
          if ($movedJarNameSet.ContainsKey($jarName)) { continue }

          $gamePath = Join-Path -Path $GameModsDir -ChildPath $jarName
          if (-not (Test-Path -LiteralPath $gamePath)) {
            Write-Verbose ("Fast-forward skip missing mod: {0}" -f $jarName)
            continue
          }
          $existingJarNames.Add($jarName)
        }

        if ($existingJarNames.Count -gt 0) {
          Write-Host ("Fast-forward: quarantining {0} mod(s) from previous isolation run..." -f $existingJarNames.Count) -ForegroundColor Cyan
          $phase = "fast_forward_move_to_quarantine"
          Update-QuarantineState -DesiredJarNames @() -PinnedJarNames @($existingJarNames.ToArray())

          foreach ($jarName in $existingJarNames) {
            if (-not $movedJarNameSet.ContainsKey($jarName)) { continue }
            $pinnedJarNameSet[$jarName.ToLowerInvariant()] = $jarName
            $item = Get-MovedItemByJarName -JarName $jarName
            if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item.GameQuarantine)) {
              Write-Verbose ("Fast-forward moved: {0} -> {1}" -f $jarName, $item.GameQuarantine)
            } else {
              Write-Verbose ("Fast-forward moved: {0}" -f $jarName)
            }
          }
        }
      }
    }

    $pinnedJarNames = @()
    if ($pinnedJarNameSet.Count -gt 0) {
      $pinnedJarNames = @($pinnedJarNameSet.Values)
    }
  }

  $baselinePinnedJarCount = 0
  $pinnedJarNamesVar = Get-Variable -Name "pinnedJarNames" -Scope 0 -ErrorAction SilentlyContinue
  if ($null -ne $pinnedJarNamesVar -and $null -ne $pinnedJarNamesVar.Value) {
    $baselinePinnedJarCount = [int]@($pinnedJarNamesVar.Value).Count
  }

Set-McccStageResult -StageResults $isolationStageResults -StageResult (Complete-McccStageAccumulator `
    -Accumulator $baselineStageResult `
    -ExtraFields @{
    BaselineOutcome = $baselineOutcome
    BaselineSucceeded = [bool]$baselineSucceeded
    BaselineSignature = $baselineSignature
    BaselineEvidenceKey = $baselineEvidenceKey
    SkipIsolation = [bool]$skipIsolation
    StopReason = $stopReason
    PinnedJarCount = [int]$baselinePinnedJarCount
  })
