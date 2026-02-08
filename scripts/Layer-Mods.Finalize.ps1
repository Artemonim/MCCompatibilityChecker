  if ($wasCtrlC) {
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Layering interrupted by user (Ctrl+C). Restoring mods..." -ForegroundColor Yellow
    Write-Host ("Phase at interruption: {0}" -f $phase) -ForegroundColor Gray
  }
  if (-not $DryRun) {
    # * Ensure the game is closed before restore/exit.
    [void](Stop-ConfiguredGameProcess -StartedAfter $layeringStartTime)
    [void](Wait-ConfiguredGameExit -StartedAfter $layeringStartTime -WarningContext "Layering cleanup")
  }
  $persistCulprits = (-not $hadError) -and ($exitCode -eq 0)

  # * Restore all quarantined mods (except culprits).
  if ($movedItems.Count -gt 0) {
    if ($hadError -and $KeepMovedModsOnFailure) {
      Write-Host "Keeping moved mods due to failure." -ForegroundColor Yellow
    } else {
      $excludeSet = @{}
      if ($persistCulprits) {
        foreach ($name in $culpritJarNames) {
          if (-not [string]::IsNullOrWhiteSpace($name)) { $excludeSet[$name] = $true }
        }
      }
      $restoreCount = 0
      foreach ($item in $movedItems) {
        if ($excludeSet.Count -gt 0 -and $excludeSet.ContainsKey($item.JarName)) { continue }
        if (-not [string]::IsNullOrWhiteSpace($item.GameQuarantine) -and (Test-Path -LiteralPath $item.GameQuarantine)) {
          $restoreGame = Restore-FromQuarantine -SourcePath $item.GameQuarantine -DestDir $GameModsDir -IsDryRun $false -AllowOverwrite ([bool]$ForceRestore)
          if ($restoreGame) { $restoreCount++ }
        }
        if ($useStorage -and -not [string]::IsNullOrWhiteSpace($item.StorageQuarantine) -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
          [void](Restore-FromQuarantine -SourcePath $item.StorageQuarantine -DestDir $StorageModsDir -IsDryRun $false -AllowOverwrite ([bool]$ForceRestore))
        }
      }
      if ($restoreCount -gt 0) {
        Write-Host ("Restored {0} mod(s) from quarantine." -f $restoreCount) -ForegroundColor Green
      }
    }
  }

  # * Move culprits to permanent legacy.
  if ($persistCulprits -and $culpritJarNames.Count -gt 0) {
    $keepGameLegacyEffective = [bool]$KeepCulpritInGameLegacy
    if (-not $useStorage -and (-not $keepGameLegacyEffective)) {
      Write-Host "Warning: storage is disabled; keeping culprit in game legacy." -ForegroundColor Yellow
      $keepGameLegacyEffective = $true
    }

    foreach ($culpritName in $culpritJarNames) {
      if ([string]::IsNullOrWhiteSpace($culpritName)) { continue }

      $culpritItem = Get-MovedItemByJarName -JarName $culpritName
      $storageSourcePath = ""
      $gameSourcePath = ""
      if ($null -ne $culpritItem) {
        $storageSourcePath = Get-FirstExistingPath -Candidates @($culpritItem.StorageQuarantine)
        $gameSourcePath = Get-FirstExistingPath -Candidates @($culpritItem.GameQuarantine)
      }
      $moveResult = Move-CulpritToLegacyAndAppendLog `
        -JarName $culpritName `
        -MinecraftVersion $mcVersionForLegacy `
        -GameModsDir $GameModsDir `
        -StorageModsDir $StorageModsDir `
        -GameLegacyFolderName $GameLegacyFolderName `
        -StorageLegacyFolderName $StorageLegacyFolderName `
        -KeepCulpritInGameLegacy $keepGameLegacyEffective `
        -StorageSourcePath $storageSourcePath `
        -GameSourcePath $gameSourcePath `
        -StorageTransferMode "Move" `
        -GameTransferMode "Move" `
        -RemoveGameIfNotKeeping:$true `
        -RequireStorageMoveForGameRemoval:$false
      $culpritStorageLegacyPath = $moveResult.StorageLegacyPath
      $culpritGameLegacyPath = $moveResult.GameLegacyPath

      $evKey = if ($culpritEvidenceKeys.ContainsKey($culpritName)) { $culpritEvidenceKeys[$culpritName] } else { "" }
      $priority = Get-DependencyAwareJarPriorityInfo -JarName $culpritName
      $priorityDecision = ""
      $decisionVar = Get-Variable -Name "dependencyPriorityDecisionByJarName" -Scope Script -ErrorAction SilentlyContinue
      if ($null -ne $decisionVar -and $decisionVar.Value -is [hashtable]) {
        $decisionMap = [hashtable]$decisionVar.Value
        $decisionKey = $culpritName.ToLowerInvariant()
        if ($decisionMap.ContainsKey($decisionKey)) {
          $decisionInfo = $decisionMap[$decisionKey]
          if ($null -ne $decisionInfo -and $decisionInfo.PSObject.Properties.Name -contains "Reason") {
            $priorityDecision = [string]$decisionInfo.Reason
          }
        }
      }
      if ([string]::IsNullOrWhiteSpace($priorityDecision)) {
        if ([bool]$priority.Known) {
          $priorityDecision = "dependency-priority: selected lower-impact tier first"
        } else {
          $priorityDecision = "dependency-priority: selected with unknown dependency metadata"
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
          CrashEvidenceKey = $evKey
          DependencyTier = [int]$priority.Tier
          DependentModCount = [int]$priority.DependentCount
          DependentModCountKnown = [bool]$priority.Known
          PriorityDecision = $priorityDecision
          Stage = "layering"
        })
    }
  }
