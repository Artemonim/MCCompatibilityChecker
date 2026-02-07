  # ── Phase 3: layering loop (tier-3, tier-2, tier-1). ──
  if ($exitCode -eq 0) {
    $layerTiers = Get-LayeringTierPlan `
      -Tier3Mods $tier3Mods `
      -Tier2Mods $tier2Mods `
      -Tier1Mods $tier1Mods `
      -CulpritJarNames $culpritJarNames `
      -MovedJarNameSet $movedJarNameSet

    for ($tierIdx = 0; $tierIdx -lt $layerTiers.Count; $tierIdx++) {
      $tierInfo = $layerTiers[$tierIdx]
      $tier = $tierInfo.Tier
      $tierMods = @($tierInfo.Mods)
      if (-not $tierMods -or $tierMods.Count -eq 0) { continue }

      if (-not $tierMods -or $tierMods.Count -eq 0) { continue }

      Write-Host ("Наслоение, уровень {0}: {1} mod(s)" -f $tier, $tierMods.Count) -ForegroundColor Cyan

      $remaining = [System.Collections.Generic.List[object]]::new(@($tierMods))
      $batchSize = 1
      $maxFabricRetries = 5
      $consecutiveFabricFails = 0
      $maxConsecutiveFabricFails = 3

      while ($remaining.Count -gt 0) {
        if ($abortLayering) { break }

        $actualBatchSize = [Math]::Min($batchSize, $remaining.Count)
        $batch = @($remaining.GetRange(0, $actualBatchSize))
        $batchNames = @($batch | ForEach-Object { $_.Name })

        $batchDisplay = if ($VerbosePreference -ne "SilentlyContinue") { $batchNames -join ", " } else { (($batchNames | Select-Object -First 3) -join ", ") + $(if ($batchNames.Count -gt 3) { "..." } else { "" }) }
        Write-Host ("  Adding batch of {0} mod(s): {1}" -f $batch.Count, $batchDisplay) -ForegroundColor Cyan

        # * Restore batch from quarantine.
        $phase = ("tier{0}_restore_batch" -f $tier)
        foreach ($batchMod in $batch) {
          $item = Get-MovedItemByJarName -JarName $batchMod.Name
          if ($null -ne $item -and $null -ne $item.GameQuarantine -and (Test-Path -LiteralPath $item.GameQuarantine)) {
            [void](Restore-FromQuarantine -SourcePath $item.GameQuarantine -DestDir $GameModsDir -IsDryRun $false -AllowOverwrite $true)
            $item.GameQuarantine = $null
          }
          if ($useStorage -and $null -ne $item -and $null -ne $item.StorageQuarantine -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
            [void](Restore-FromQuarantine -SourcePath $item.StorageQuarantine -DestDir $StorageModsDir -IsDryRun $false -AllowOverwrite $true)
            $item.StorageQuarantine = $null
          }
          if ($movedJarNameSet.ContainsKey($batchMod.Name)) {
            $null = $movedJarNameSet.Remove($batchMod.Name)
          }
        }

        # * Determine if this is the final batch (last batch of last tier with mods).
        $isLastBatchInTier = ($remaining.Count -le $actualBatchSize)
        $hasMoreTierMods = $false
        for ($futureIdx = $tierIdx + 1; $futureIdx -lt $layerTiers.Count; $futureIdx++) {
          $futureMods = @($layerTiers[$futureIdx].Mods)
          $futureMods = @($futureMods | Where-Object { -not $culpritJarNames.Contains($_.Name) })
          $futureMods = @($futureMods | Where-Object { $movedJarNameSet.ContainsKey($_.Name) })
          if ($futureMods.Count -gt 0) { $hasMoreTierMods = $true; break }
        }
        $isFinalBatch = $isLastBatchInTier -and (-not $hasMoreTierMods)

        # * Launch and check.
        $phase = ("tier{0}_layer_launch" -f $tier)
        $layerResult = Invoke-LayeringLaunchAndCheck -PhasePrefix ("tier{0}_batch" -f $tier) -LeaveGameRunning:$isFinalBatch

        # * User closed the game manually. No crash dialog = game was running fine.
        if ($layerResult.Type -eq "UserExit") {
          Write-Host "  User closed the game. Treating batch as clean." -ForegroundColor Yellow
          Update-McccHashCachePassedJar -JarNames $batchNames -Minecraft $mcVersionForLegacy
          $null = $remaining.RemoveRange(0, $actualBatchSize)
          $batchSize = $batchSize * 2
          Write-Host ("  Remaining: {0}" -f $remaining.Count) -ForegroundColor Green
          continue
        }

        if ($layerResult.Type -eq "Success") {
          # * Batch is clean. Advance.
          $null = $remaining.RemoveRange(0, $actualBatchSize)
          $batchSize = $batchSize * 2
          $consecutiveFabricFails = 0
          Write-Host ("  Batch clean. Remaining: {0}" -f $remaining.Count) -ForegroundColor Green
          Update-McccHashCachePassedJar -JarNames $batchNames -Minecraft $mcVersionForLegacy
          continue
        }

        if ($layerResult.Type -eq "FabricDialog") {
          # * Missing dependencies — restore them and retry same batch.
          $fabricRetry = 0
          while ($layerResult.Type -eq "FabricDialog" -and $fabricRetry -lt $maxFabricRetries) {
            $fabricRetry++
            $restoredCount = Restore-MissingDependency -MissingDepIds $layerResult.MissingDepIds
            if ($restoredCount -eq 0) {
              Write-Host "  Fabric dialog but no restorable dependencies. Treating as crash." -ForegroundColor Yellow
              break
            }
            Write-Host ("  Restored {0} dep(s). Retrying batch..." -f $restoredCount) -ForegroundColor Cyan
            $layerResult = Invoke-LayeringLaunchAndCheck -PhasePrefix ("tier{0}_fabric_retry" -f $tier) -LeaveGameRunning:$isFinalBatch
          }

          if ($layerResult.Type -eq "Success") {
            $null = $remaining.RemoveRange(0, $actualBatchSize)
            $batchSize = $batchSize * 2
            $consecutiveFabricFails = 0
            Write-Host ("  Batch clean after dep restore. Remaining: {0}" -f $remaining.Count) -ForegroundColor Green
            Update-McccHashCachePassedJar -JarNames $batchNames -Minecraft $mcVersionForLegacy
            continue
          }
          if ($layerResult.Type -eq "FabricDialog") {
            # * Re-quarantine the problematic batch mods so they don't contaminate
            # * subsequent batches and tiers.
            Write-Host ("  Persistent Fabric dialog. Re-quarantining batch of {0} mod(s)." -f $batch.Count) -ForegroundColor Yellow
            foreach ($batchMod in $batch) {
              $gamePath = Join-Path -Path $GameModsDir -ChildPath $batchMod.Name
              if (Test-Path -LiteralPath $gamePath) {
                $dest = Move-ToQuarantine -SourcePath $gamePath -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
                if ($null -ne $dest) {
                  $existingItem = Get-MovedItemByJarName -JarName $batchMod.Name
                  if ($null -ne $existingItem) {
                    $existingItem.GameQuarantine = $dest
                  } else {
                    [void](Add-MovedItemRecord -JarName $batchMod.Name -GameSource $gamePath -GameQuarantine $dest -StorageSource $null -StorageQuarantine $null)
                  }
                  if (-not $movedJarNameSet.ContainsKey($batchMod.Name)) {
                    $movedJarNameSet[$batchMod.Name] = $true
                  }
                }
              }
            }
            $null = $remaining.RemoveRange(0, $actualBatchSize)
            $batchSize = 1
            $hadUnresolvableFabric = $true
            $consecutiveFabricFails++
            if ($consecutiveFabricFails -ge $maxConsecutiveFabricFails) {
              Write-Host ("  {0} consecutive Fabric failures. Stopping уровень {1}." -f $consecutiveFabricFails, $tier) -ForegroundColor Yellow
              break
            }
            continue
          }
          # * User closed the game during Fabric retry. No crash = batch is clean.
          if ($layerResult.Type -eq "UserExit") {
            Write-Host "  User closed the game during Fabric retry. Treating batch as clean." -ForegroundColor Yellow
            Update-McccHashCachePassedJar -JarNames $batchNames -Minecraft $mcVersionForLegacy
            $null = $remaining.RemoveRange(0, $actualBatchSize)
            $batchSize = $batchSize * 2
            Write-Host ("  Remaining: {0}" -f $remaining.Count) -ForegroundColor Green
            continue
          }
          # * Fall through to crash handling.
        }

        . $layerBatchTriagePath

        # * Unexpected outcome — stop уровень.
        Write-Host ("  Unexpected outcome: {0}. Stopping уровень." -f $layerResult.Type) -ForegroundColor Yellow
        break
      }

      if ($abortLayering) { break }
    }
  }
