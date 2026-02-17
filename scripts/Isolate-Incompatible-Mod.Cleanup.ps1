if ($null -eq $isolationStageResults -or -not ($isolationStageResults -is [hashtable])) {
  $isolationStageResults = @{}
}
$cleanupStageResult = New-McccStageAccumulator -Stage "Isolation.Cleanup"
$cleanupRestoreCount = 0

if ($wasCtrlC) {
  Write-Host "" -ForegroundColor Yellow
  Write-Host "Isolation interrupted by user (Ctrl+C). Restoring mods..." -ForegroundColor Yellow
  Write-Host ("Phase at interruption: {0}" -f $phase) -ForegroundColor Gray
  Add-McccStageWarning `
    -Accumulator $cleanupStageResult `
    -Category "runtime" `
    -Code "ISOLATION_INTERRUPTED_CTRL_C" `
    -Message "Isolation interrupted by user (Ctrl+C). Restoring mods..." `
    -Context @{
    Phase = $phase
  } | Out-Null
}
if (-not $DryRun) {
  # * Ensure the game is closed before restore/exit.
  [void](Stop-ConfiguredGameProcess -StartedAfter $isolationStartTime)
  [void](Wait-ConfiguredGameExit -StartedAfter $isolationStartTime -WarningContext "Isolation cleanup")
}
if (-not $DryRun -and $movedItems.Count -gt 0) {
  if ($hadError -and $KeepMovedModsOnFailure) {
    Write-Host "Keeping moved mods due to failure." -ForegroundColor Yellow
    Add-McccStageWarning `
      -Accumulator $cleanupStageResult `
      -Category "cleanup" `
      -Code "KEEP_MOVED_MODS_ON_FAILURE" `
      -Message "Keeping moved mods due to failure." `
      -Context @{
      MovedItemCount = [int]$movedItems.Count
      KeepMovedModsOnFailure = [bool]$KeepMovedModsOnFailure
    } | Out-Null
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
      if (-not [string]::IsNullOrWhiteSpace($item.GameQuarantine)) {
        $restoreGame = Restore-FromQuarantine -SourcePath $item.GameQuarantine `
          -DestDir $GameModsDir `
          -IsDryRun $false `
          -AllowOverwrite ([bool]$ForceRestore)
        if ($restoreGame) {
          $restoreCount++
          Write-Verbose ("Restored game mod: {0}" -f $restoreGame)
        }
      }
      if ($useStorage -and -not [string]::IsNullOrWhiteSpace($item.StorageQuarantine)) {
        $restoreStorage = Restore-FromQuarantine -SourcePath $item.StorageQuarantine `
          -DestDir $StorageModsDir `
          -IsDryRun $false `
          -AllowOverwrite ([bool]$ForceRestore)
        if ($restoreStorage) {
          Write-Verbose ("Restored storage mod: {0}" -f $restoreStorage)
        }
      }
    }
    $cleanupRestoreCount = [int]$restoreCount
    if ($restoreCount -gt 0) {
      Write-Host ("Restored {0} mod(s) from quarantine." -f $restoreCount) -ForegroundColor Green
    }
  }
}

. $isolateCulpritFinalizePath

Set-McccStageResult -StageResults $isolationStageResults -StageResult (Complete-McccStageAccumulator `
    -Accumulator $cleanupStageResult `
    -ExtraFields @{
    DryRun = [bool]$DryRun
    HadError = [bool]$hadError
    KeepMovedModsOnFailure = [bool]$KeepMovedModsOnFailure
    RestoredCount = [int]$cleanupRestoreCount
    MovedItemCount = [int]$movedItems.Count
  })
