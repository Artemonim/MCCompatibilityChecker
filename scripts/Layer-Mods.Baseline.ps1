  # ── Phase 1: quarantine all non-tier-4 mods. ──
  $phase = "initial_quarantine"
  Write-Host "Quarantining all non-core mods..." -ForegroundColor Cyan
  foreach ($mod in $nonCoreMods) {
    $gameDest = Move-ToQuarantine -SourcePath $mod.FullName -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
    $storageDest = $null
    if ($useStorage) {
      $storagePath = Join-Path -Path $StorageModsDir -ChildPath $mod.Name
      if (Test-Path -LiteralPath $storagePath) {
        $storageDest = Move-ToQuarantine -SourcePath $storagePath -DestDir $storageQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
      }
    }
    [void](Add-MovedItemRecord -JarName $mod.Name `
        -GameSource $mod.FullName `
        -GameQuarantine $gameDest `
        -StorageSource $(if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $mod.Name } else { $null }) `
        -StorageQuarantine $storageDest)
  }
  Write-Host ("Quarantined {0} non-core mod(s)." -f $nonCoreMods.Count) -ForegroundColor Gray

  # ── Phase 2: baseline launch with tier-4 only. ──
  $phase = "baseline_tier4"
  $baselineWithHashCachedMods = ($script:mcccCacheEnabled -and $script:mcccKnownGoodJarNameSet.Count -gt 0)
  $baselineRetriedCoreOnly = $false
  $baselineLabel = "Baseline: launching with core libraries only (tier 4)."
  if ($baselineWithHashCachedMods) {
    $baselineLabel = "Baseline: launching with core libraries (tier 4) plus hash-cached mods."
  }
  Write-Host $baselineLabel -ForegroundColor Cyan
  $baselineResult = Invoke-LayeringLaunchAndCheck -PhasePrefix "baseline_tier4"

  if ($baselineResult.Type -eq "Crash" -and $baselineWithHashCachedMods) {
    Write-Host "Baseline with hash-cached mods crashed. Retrying strict core-only baseline (tier 4)." -ForegroundColor Yellow
    $baselineRetriedCoreOnly = $true
    $cacheEnabledBeforeRetry = [bool]$script:mcccCacheEnabled
    $script:mcccCacheEnabled = $false
    try {
      $baselineResult = Invoke-LayeringLaunchAndCheck -PhasePrefix "baseline_tier4_core_only_retry"
    } finally {
      if ($baselineResult.Type -ne "Success") {
        $script:mcccCacheEnabled = $cacheEnabledBeforeRetry
      }
    }

    if ($baselineResult.Type -eq "Success") {
      Write-Host "Strict core-only baseline succeeded. Hash-cached mods are excluded for this layering run." -ForegroundColor Yellow
    }
  }

  if ($baselineResult.Type -eq "Crash") {
    if ($baselineRetriedCoreOnly -or (-not $baselineWithHashCachedMods)) {
      Write-Host "Core libraries (tier 4) crash on their own. Layering is impossible." -ForegroundColor Red
    } else {
      Write-Host "Baseline crash happened with tier 4 plus hash-cached mods. Core-only baseline was not isolated." -ForegroundColor Red
    }
    Write-Host "Manual diagnostics required: check tier 4 mods or use standard isolation." -ForegroundColor Yellow
    $exitCode = 2
    # ! Fall through to finally for restore.
  } elseif ($baselineResult.Type -eq "FabricDialog") {
    $restoredCount = Restore-MissingDependency -MissingDepIds $baselineResult.MissingDepIds
    if ($restoredCount -gt 0) {
      Write-Host ("Restored {0} missing dependencies for tier 4. Retrying launch..." -f $restoredCount) -ForegroundColor Cyan
      $baselineResult = Invoke-LayeringLaunchAndCheck -PhasePrefix "baseline_tier4_retry"
      if ($baselineResult.Type -ne "Success") {
        Write-Host ("Tier 4 retry failed: {0}. Cannot continue." -f $baselineResult.Type) -ForegroundColor Red
        $exitCode = 2
      }
    } else {
      Write-Host "Tier 4 baseline check showed a Fabric dialog, but no restorable dependencies were found." -ForegroundColor Red
      $exitCode = 2
    }
  }

  if ($baselineResult.Type -eq "Success" -and $baselineResult.PSObject.Properties.Name -contains "LogSnapshot") {
    $mcVersionForLegacy = Get-MinecraftVersionFromLog -Lines $baselineResult.LogSnapshot.Lines
  }

  if ($baselineResult.Type -eq "Success") {
    $tier4Names = @($tier4Mods | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    Update-McccHashCachePassedJar -JarNames $tier4Names -Minecraft $mcVersionForLegacy
  }
