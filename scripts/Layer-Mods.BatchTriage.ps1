        # * Crash handling: try basic algorithm, then binary isolation.
        if ($layerResult.Type -eq "Crash") {
          $phase = ("tier{0}_crash_identify" -f $tier)

          if ($mcVersionForLegacy -eq "unknown" -and $null -ne $layerResult.LogSnapshot) {
            $mcVersionForLegacy = Get-MinecraftVersionFromLog -Lines $layerResult.LogSnapshot.Lines
          }

          # * Step A: basic algorithm — read log, identify culprit.
          $logCulprits = @()
          if ($null -ne $layerResult.LogSnapshot) {
            $logCulprits = @(Find-CulpritFromLog -LogLines $layerResult.LogSnapshot.Lines -BatchMods $batch)
          }

          if ($logCulprits -and $logCulprits.Count -gt 0) {
            foreach ($cj in $logCulprits) {
              Write-Host ("  Log-identified culprit: {0}" -f $cj.Name) -ForegroundColor Green
              $logEvKey = if ($null -ne $layerResult.LogSnapshot) { Get-ErrorEvidenceKey -Lines $layerResult.LogSnapshot.Lines -MaxLines $ErrorSignatureLineLimit } else { "" }
              Move-CulpritToLegacy -JarName $cj.Name -EvidenceKey $logEvKey
            }
            # * Remove culprits from remaining, don't advance batchSize.
            $culpritNameSet = @{}
            foreach ($cj in $logCulprits) { $culpritNameSet[$cj.Name.ToLowerInvariant()] = $true }
            $newRemaining = [System.Collections.Generic.List[object]]::new()
            foreach ($m in $remaining) {
              if (-not $culpritNameSet.ContainsKey($m.Name.ToLowerInvariant())) {
                $newRemaining.Add($m)
              }
            }
            $remaining = $newRemaining
            # * Reset batch size after a culprit is found to re-probe carefully.
            $batchSize = 1
            continue
          }

          # * Tier-1 optimization: for deep crash diagnosis, keep only the current
          # * problematic batch active and park the rest of active tier-1 mods.
          $tier1NarrowingParkedJarNames = @()
          if ($tier -eq 1) {
            $tier1NarrowingParkedJarNames = @(Invoke-Tier1BatchNarrowing -BatchJarNames $batchNames)
          }

          # * Step B: binary isolation within the batch.
          if ($batch.Count -le 1) {
            # * Single mod batches can yield false positives when the crash persists for other reasons.
            # * Confirm by re-probing WITHOUT this mod before blaming it.
            $singleJarName = [string]$batch[0].Name
            Write-Host ("  Single mod batch crashed: {0}. Re-probing without it..." -f $singleJarName) -ForegroundColor Yellow

            $singleGamePath = Join-Path -Path $GameModsDir -ChildPath $singleJarName
            $singleStoragePath = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $singleJarName } else { $null }
            $singleGameDest = $null
            $singleStorageDest = $null
            if (Test-Path -LiteralPath $singleGamePath) {
              $singleGameDest = Move-ToQuarantine -SourcePath $singleGamePath -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
            }
            if ($useStorage -and $singleStoragePath -and (Test-Path -LiteralPath $singleStoragePath) -and $storageQuarantineDir) {
              $singleStorageDest = Move-ToQuarantine -SourcePath $singleStoragePath -DestDir $storageQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
            }
            if ($null -ne $singleGameDest -or $null -ne $singleStorageDest) {
              [void](Add-MovedItemRecord -JarName $singleJarName `
                  -GameSource $singleGamePath `
                  -GameQuarantine $singleGameDest `
                  -StorageSource $singleStoragePath `
                  -StorageQuarantine $singleStorageDest)
            }

            $phase = ("tier{0}_single_confirm" -f $tier)
            $confirmResult = Invoke-LayeringLaunchAndCheck -PhasePrefix ("tier{0}_single_confirm" -f $tier)
            if ($confirmResult.Type -eq "Success" -or $confirmResult.Type -eq "UserExit") {
              Write-Host ("  Confirmed culprit: {0}" -f $singleJarName) -ForegroundColor Green
              $singleEvKey = if ($null -ne $layerResult.LogSnapshot) { Get-ErrorEvidenceKey -Lines $layerResult.LogSnapshot.Lines -MaxLines $ErrorSignatureLineLimit } else { "" }
              Move-CulpritToLegacy -JarName $singleJarName -EvidenceKey $singleEvKey
              $null = $remaining.RemoveAt(0)
              $batchSize = 1
              if ($tier -eq 1 -and $tier1NarrowingParkedJarNames.Count -gt 0) {
                $tier1ProbeOk = Complete-Tier1BatchNarrowing `
                  -ParkedJarNames $tier1NarrowingParkedJarNames `
                  -RunConsistencyProbe $true `
                  -ProbePhasePrefix ("tier{0}_single_probe_restored" -f $tier)
                if (-not $tier1ProbeOk) {
                  $abortLayering = $true
                  $exitCode = 4
                  break
                }
              }
              continue
            }

            Write-Host ("  Re-probe still fails without {0}. Not blaming it; aborting Layering." -f $singleJarName) -ForegroundColor Yellow

            # * Restore the mod back before abort to avoid partial state.
            $item = Get-MovedItemByJarName -JarName $singleJarName
            if ($null -ne $item -and $null -ne $item.GameQuarantine -and (Test-Path -LiteralPath $item.GameQuarantine)) {
              [void](Restore-FromQuarantine -SourcePath $item.GameQuarantine -DestDir $GameModsDir -IsDryRun $false -AllowOverwrite $true)
              $item.GameQuarantine = $null
            }
            if ($useStorage -and $null -ne $item -and $null -ne $item.StorageQuarantine -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
              [void](Restore-FromQuarantine -SourcePath $item.StorageQuarantine -DestDir $StorageModsDir -IsDryRun $false -AllowOverwrite $true)
              $item.StorageQuarantine = $null
            }
            if ($movedJarNameSet.ContainsKey($singleJarName)) {
              $null = $movedJarNameSet.Remove($singleJarName)
            }

            if ($tier -eq 1 -and $tier1NarrowingParkedJarNames.Count -gt 0) {
              [void](Complete-Tier1BatchNarrowing `
                  -ParkedJarNames $tier1NarrowingParkedJarNames `
                  -RunConsistencyProbe $false)
            }

            $abortLayering = $true
            $exitCode = 4
            break
          }

          Write-Host ("  Basic algorithm could not identify culprit. Running binary Isolation on {0} mod(s)." -f $batch.Count) -ForegroundColor Cyan

          # * Capture crash signature as baseline for binary isolation.
          $crashSignature = ""
          $crashEvidenceKey = ""
          if ($null -ne $layerResult.LogSnapshot) {
            $crashSignature = Get-ErrorSignature -Lines $layerResult.LogSnapshot.Lines `
              -MaxLines $ErrorSignatureLineLimit `
              -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
            $crashEvidenceKey = Get-ErrorEvidenceKey -Lines $layerResult.LogSnapshot.Lines -MaxLines $ErrorSignatureLineLimit
          }

          # * Multi-culprit binary isolation loop.
          # * A single batch may contain several independently crashing mods.
          # * Binary search identifies one candidate at a time; after quarantining
          # * it, the search restarts on the reduced set until the crash is resolved.
          $batchForBinary = @($batch)
          $multiCulpritIteration = 0
          $multiCulpritMax = 32
          $binaryResolved = $false

          while ($batchForBinary.Count -gt 0 -and $multiCulpritIteration -lt $multiCulpritMax) {
            $multiCulpritIteration++

            # * PinnedJarNames = everything currently quarantined that is NOT in the binary batch.
            $binaryPinned = @($movedJarNameSet.Keys | Where-Object {
                $jarName = $_
                $inBatch = $false
                foreach ($bm in $batchForBinary) { if ($bm.Name -eq $jarName) { $inBatch = $true; break } }
                -not $inBatch
              })

            $phase = ("tier{0}_binary_isolation_{1}" -f $tier, $multiCulpritIteration)
            $binaryResult = Invoke-BinaryIsolation -Mods $batchForBinary `
              -BaselineSignature $crashSignature `
              -BaselineEvidenceKey $crashEvidenceKey `
              -PinnedJarNames $binaryPinned

            if ($binaryResult.Reason -eq "all_removed_no_change") {
              if ($multiCulpritIteration -eq 1) {
                # * First attempt: crash persists without ANY batch mods.
                Write-Host "  Crash persists without batch mods. Aborting Layering." -ForegroundColor Yellow
                $abortLayering = $true
                $exitCode = 4
              } else {
                # * Subsequent attempt: remaining batch mods are clean.
                Write-Host ("  Remaining {0} batch mod(s) verified clean after removing {1} culprit(s)." -f $batchForBinary.Count, ($multiCulpritIteration - 1)) -ForegroundColor Green
                $binaryResolved = $true
              }
              break
            }

            $binaryRemaining = @($binaryResult.Remaining)
            if (-not $binaryRemaining -or $binaryRemaining.Count -eq 0) {
              Write-Host "  Binary Isolation returned empty set. Skipping batch." -ForegroundColor Yellow
              break
            }

            foreach ($brMod in $binaryRemaining) {
              # * Quarantine this single mod and re-test.
              $gamePath = Join-Path -Path $GameModsDir -ChildPath $brMod.Name
              if (Test-Path -LiteralPath $gamePath) {
                $dest = Move-ToQuarantine -SourcePath $gamePath -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
                if ($null -ne $dest) {
                  [void](Add-MovedItemRecord -JarName $brMod.Name -GameSource $gamePath -GameQuarantine $dest -StorageSource $null -StorageQuarantine $null)
                }
              }

              $phase = ("tier{0}_binary_linear_check_{1}" -f $tier, $multiCulpritIteration)
              $linearResult = Invoke-LayeringLaunchAndCheck -PhasePrefix ("tier{0}_binary_linear_{1}" -f $tier, $multiCulpritIteration)

              if ($linearResult.Type -eq "Success" -or $linearResult.Type -eq "UserExit") {
                # * Removing this mod fixed it — it's the (last) culprit.
                Write-Host ("  Binary Isolation culprit: {0}" -f $brMod.Name) -ForegroundColor Green
                Move-CulpritToLegacy -JarName $brMod.Name -EvidenceKey $crashEvidenceKey
                $binaryResolved = $true
                break
              } else {
                # * Still crashes — this mod is one of multiple culprits.
                # * Keep it quarantined and search for more.
                Write-Host ("  Multi-culprit: {0} (crash persists; searching for more)" -f $brMod.Name) -ForegroundColor Yellow
                Move-CulpritToLegacy -JarName $brMod.Name -EvidenceKey $crashEvidenceKey
                # * Track this mod as quarantined so it stays pinned in the next iteration.
                $movedJarNameSet[$brMod.Name] = $true
                $batchForBinary = @($batchForBinary | Where-Object { $_.Name -ne $brMod.Name })

                # * Update baseline crash signature for the next iteration.
                # * The remaining crash may have a different root cause now.
                if ($null -ne $linearResult.LogSnapshot) {
                  $crashSignature = Get-ErrorSignature -Lines $linearResult.LogSnapshot.Lines `
                    -MaxLines $ErrorSignatureLineLimit `
                    -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
                  $crashEvidenceKey = Get-ErrorEvidenceKey -Lines $linearResult.LogSnapshot.Lines -MaxLines $ErrorSignatureLineLimit
                }
                break
              }
            }

            if ($binaryResolved) { break }
          }

          if ($abortLayering) {
            if ($tier -eq 1 -and $tier1NarrowingParkedJarNames.Count -gt 0) {
              [void](Complete-Tier1BatchNarrowing `
                  -ParkedJarNames $tier1NarrowingParkedJarNames `
                  -RunConsistencyProbe $false)
            }
            break
          }

          # * Post-resolution: update remaining list and hash cache.
          if ($binaryResolved -or $batchForBinary.Count -eq 0) {
            # * Batch fully processed: culprit(s) quarantined, rest verified clean.
            $cleanBatchNames = @($batch | ForEach-Object { $_.Name } | Where-Object {
                -not $culpritJarNames.Contains($_)
              })
            if ($cleanBatchNames.Count -gt 0) {
              Update-McccHashCachePassedJar -JarNames $cleanBatchNames -Minecraft $mcVersionForLegacy
            }
            $null = $remaining.RemoveRange(0, $actualBatchSize)
          } else {
            # * Could not fully resolve the batch. Remove found culprits from remaining.
            $culpritNameSet = @{}
            foreach ($cn in $culpritJarNames) { $culpritNameSet[$cn.ToLowerInvariant()] = $true }
            $newRemaining = [System.Collections.Generic.List[object]]::new()
            foreach ($m in $remaining) {
              if (-not $culpritNameSet.ContainsKey($m.Name.ToLowerInvariant())) {
                $newRemaining.Add($m)
              }
            }
            $remaining = $newRemaining
          }
          $batchSize = 1
          if ($tier -eq 1 -and $tier1NarrowingParkedJarNames.Count -gt 0) {
            $needTier1Probe = ($binaryResolved -or $batchForBinary.Count -eq 0)
            $tier1ProbeOk = Complete-Tier1BatchNarrowing `
              -ParkedJarNames $tier1NarrowingParkedJarNames `
              -RunConsistencyProbe $needTier1Probe `
              -ProbePhasePrefix ("tier{0}_binary_probe_restored" -f $tier)
            if (-not $tier1ProbeOk) {
              $abortLayering = $true
              $exitCode = 4
              break
            }
          }
          continue
        }
