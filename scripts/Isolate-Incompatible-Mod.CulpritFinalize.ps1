  if (-not $DryRun -and (-not $hadError) -and $culpritJarNames -and $culpritJarNames.Count -gt 0) {
    # * Prefer moving culprits into Storage legacy (source of truth).
    # * Keep a game-legacy copy only when explicitly requested (or when storage is unavailable).
    $keepGameLegacyEffective = [bool]$KeepCulpritInGameLegacy
    if (-not $useStorage -and (-not $keepGameLegacyEffective)) {
      Write-Host "Warning: storage is disabled/unavailable; keeping culprit in game legacy to avoid data loss." -ForegroundColor Yellow
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
          Write-Host ("Warning: culprit jar not found in storage for legacy move: {0}" -f $culpritName) -ForegroundColor Yellow
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
        Write-Host ("Warning: culprit jar was not moved to any legacy location: {0}" -f $culpritName) -ForegroundColor Yellow
      }
      if (-not $keepGameLegacyEffective -and (-not $storageOk)) {
        Write-Host ("Warning: storage legacy move did not happen; keeping culprit in quarantine: {0}" -f $culpritName) -ForegroundColor Yellow
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
