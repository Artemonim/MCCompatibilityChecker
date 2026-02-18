if ($null -eq $isolationStageResults -or -not ($isolationStageResults -is [hashtable])) {
  $isolationStageResults = @{}
}
$culpritFinalizeStageResult = New-McccStageAccumulator -Stage "Isolation.CulpritFinalize"

  if (-not $DryRun -and (-not $hadError) -and $culpritJarNames -and $culpritJarNames.Count -gt 0) {
    # * Prefer moving culprits into Storage legacy (source of truth).
    # * Keep a game-legacy copy only when explicitly requested (or when storage is unavailable).
    $keepGameLegacyEffective = [bool]$KeepCulpritInGameLegacy
    if (-not $useStorage -and (-not $keepGameLegacyEffective)) {
      $storageDisabledWarning = "Warning: storage is disabled/unavailable; keeping culprit in game legacy to avoid data loss."
      Write-Host $storageDisabledWarning -ForegroundColor Yellow
      Add-McccStageWarning `
        -Accumulator $culpritFinalizeStageResult `
        -Category "storage" `
        -Code "STORAGE_UNAVAILABLE_KEEP_GAME_LEGACY" `
        -Message $storageDisabledWarning `
        -Context @{
        UseStorage = [bool]$useStorage
        KeepCulpritInGameLegacyRequested = [bool]$KeepCulpritInGameLegacy
      } | Out-Null
      $keepGameLegacyEffective = $true
    }

    foreach ($culpritName in $culpritJarNames) {
      if ([string]::IsNullOrWhiteSpace($culpritName)) { continue }

      $culpritItem = Get-MovedItemByJarName -JarName $culpritName
      $storageSourcePath = ""
      $gameSourcePath = ""
      if ($useStorage) {
        $storageSourcePath = Get-FirstExistingPath -Candidates @(
          $(if ($null -ne $culpritItem) { $culpritItem.StorageQuarantine } else { "" }),
          (Join-Path -Path $StorageModsDir -ChildPath $culpritName)
        )
        if ([string]::IsNullOrWhiteSpace($storageSourcePath)) {
          $storageMissingWarning = ("Warning: culprit jar not found in storage for legacy move: {0}" -f $culpritName)
          Write-Host $storageMissingWarning -ForegroundColor Yellow
          Add-McccStageWarning `
            -Accumulator $culpritFinalizeStageResult `
            -Category "storage" `
            -Code "CULPRIT_STORAGE_SOURCE_NOT_FOUND" `
            -Message $storageMissingWarning `
            -Context @{
            JarName = $culpritName
            StorageModsDir = $StorageModsDir
          } | Out-Null
        }
      }
      $gameSourcePath = Get-FirstExistingPath -Candidates @(
        $(if ($null -ne $culpritItem) { $culpritItem.GameQuarantine } else { "" }),
        (Join-Path -Path $GameModsDir -ChildPath $culpritName)
      )

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
        -RequireStorageMoveForGameRemoval:$true

      $storageOk = (-not $useStorage) -or $moveResult.StorageMoved
      if ($keepGameLegacyEffective -and (-not $moveResult.GameMoved) -and (-not $storageOk)) {
        $noLegacyMoveWarning = ("Warning: culprit jar was not moved to any legacy location: {0}" -f $culpritName)
        Write-Host $noLegacyMoveWarning -ForegroundColor Yellow
        Add-McccStageWarning `
          -Accumulator $culpritFinalizeStageResult `
          -Category "legacy_move" `
          -Code "CULPRIT_NOT_MOVED_TO_LEGACY" `
          -Message $noLegacyMoveWarning `
          -Context @{
          JarName = $culpritName
          KeepGameLegacyEffective = [bool]$keepGameLegacyEffective
          UseStorage = [bool]$useStorage
        } | Out-Null
      }
      if (-not $keepGameLegacyEffective -and (-not $storageOk)) {
        $storageLegacyMissWarning = ("Warning: storage legacy move did not happen; keeping culprit in quarantine: {0}" -f $culpritName)
        Write-Host $storageLegacyMissWarning -ForegroundColor Yellow
        Add-McccStageWarning `
          -Accumulator $culpritFinalizeStageResult `
          -Category "legacy_move" `
          -Code "CULPRIT_STORAGE_LEGACY_MOVE_MISSED" `
          -Message $storageLegacyMissWarning `
          -Context @{
          JarName = $culpritName
          KeepGameLegacyEffective = [bool]$keepGameLegacyEffective
          StorageSourcePath = $storageSourcePath
        } | Out-Null
        continue
      }

      $culpritStorageLegacyPath = $moveResult.StorageLegacyPath
      $culpritGameLegacyPath = $moveResult.GameLegacyPath

      $evKey = if ($script:activeBaselineEvidenceKey) { $script:activeBaselineEvidenceKey } else { "" }
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
          Stage = "isolation"
        })
    }
  }

Set-McccStageResult -StageResults $isolationStageResults -StageResult (Complete-McccStageAccumulator `
    -Accumulator $culpritFinalizeStageResult `
    -ExtraFields @{
    DryRun = [bool]$DryRun
    HadError = [bool]$hadError
    CulpritCount = [int]@($culpritJarNames).Count
    CulpritMoveCount = [int]$culpritMoves.Count
    UseStorage = [bool]$useStorage
  })
