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
  $baselineLabel = "Baseline: launching with core libraries only (tier 4)."
  if ($script:mcccCacheEnabled -and $script:mcccKnownGoodJarNameSet.Count -gt 0) {
    $baselineLabel = "Baseline: launching with core libraries (tier 4) plus hash-cached mods."
  }
  Write-Host $baselineLabel -ForegroundColor Cyan
  $baselineResult = Invoke-LayeringLaunchAndCheck -PhasePrefix "baseline_tier4"

  if ($baselineResult.Type -eq "Crash") {
    Write-Host "Core-библиотеки (уровень 4) сами по себе вызывают краш. Наслоение невозможно." -ForegroundColor Red
    Write-Host "Требуется ручная диагностика: проверьте моды уровня 4 или используйте стандартную изоляцию." -ForegroundColor Yellow
    $exitCode = 2
    # ! Fall through to finally for restore.
  } elseif ($baselineResult.Type -eq "FabricDialog") {
    $restoredCount = Restore-MissingDependency -MissingDepIds $baselineResult.MissingDepIds
    if ($restoredCount -gt 0) {
      Write-Host ("Восстановлено {0} отсутствующих зависимостей для уровня 4. Повторный запуск..." -f $restoredCount) -ForegroundColor Cyan
      $baselineResult = Invoke-LayeringLaunchAndCheck -PhasePrefix "baseline_tier4_retry"
      if ($baselineResult.Type -ne "Success") {
        Write-Host ("Повторный запуск уровня 4 провалился: {0}. Невозможно продолжить." -f $baselineResult.Type) -ForegroundColor Red
        $exitCode = 2
      }
    } else {
      Write-Host "Базовая проверка уровня 4 показала диалог Fabric, но восстанавливаемых зависимостей не найдено." -ForegroundColor Red
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
