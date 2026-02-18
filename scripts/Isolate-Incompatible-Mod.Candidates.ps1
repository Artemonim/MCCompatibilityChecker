if ($null -eq $isolationStageResults -or -not ($isolationStageResults -is [hashtable])) {
  $isolationStageResults = @{}
}
$candidatesStageResult = New-McccStageAccumulator -Stage "Isolation.Candidates"

$candidateMods = @(Get-McccJarFiles -RootPaths @($GameModsDir) -SortBy "LastWriteTime" -Descending $true -EnumerationErrorAction "Stop")

$script:dependencyAwareTierByJarName = @{}
$script:dependencyAwareStatsByJarName = @{}
$script:dependencyPriorityDecisionByJarName = @{}
$script:currentDependencyTier = 0
$script:dependencyMapByModId = @{}
$script:dependencyMapProvidedIdsByJar = @{}
$script:dependencyMapScanPath = ""
$script:blockedByDependency = $false
$script:blockedDependencyMissing = @()
$script:blockedDependencyRequiring = @()
$script:blockedDependencyContext = ""

if ($ExcludeJarNames -and $ExcludeJarNames.Count -gt 0) {
  $excludeSet = @{}
  foreach ($name in $ExcludeJarNames) {
    if (-not [string]::IsNullOrWhiteSpace($name)) {
      $excludeSet[$name.ToLowerInvariant()] = $true
    }
  }
  $candidateMods = @($candidateMods | Where-Object { -not $excludeSet.ContainsKey($_.Name.ToLowerInvariant()) })
}

if ($MaxModsToTest -gt 0 -and $candidateMods.Count -gt $MaxModsToTest) {
  $candidateMods = @($candidateMods | Select-Object -First $MaxModsToTest)
}

# * Optional: skip mods that already passed in prior sessions (MCCC.json SHA256 cache).
$script:mcccCacheEnabled = $false
$script:mcccCachePath = ""
$script:mcccCache = $null
$script:mcccKnownGoodJarNameSet = @{}

if ((-not $DryRun) -and $UseHashCache) {
  $script:mcccCachePath = Get-McccHashCachePath -GameModsDir $GameModsDir -FileName $HashCacheFileName
  $script:mcccCache = Read-McccHashCache -Path $script:mcccCachePath
  $script:mcccCacheEnabled = $true

  # * Ensure the cache file exists so it can be inspected/edited by the user.
  try {
    if (-not [string]::IsNullOrWhiteSpace($script:mcccCachePath) -and -not (Test-Path -LiteralPath $script:mcccCachePath)) {
      Write-McccHashCache -Path $script:mcccCachePath -Cache $script:mcccCache
    }
  } catch {
    $cacheCreateWarning = ("Warning: failed to create hash cache file: {0}" -f $_.Exception.Message)
    Write-Host $cacheCreateWarning -ForegroundColor Yellow
    Add-McccStageWarning `
      -Accumulator $candidatesStageResult `
      -Category "hash_cache" `
      -Code "HASH_CACHE_FILE_CREATE_FAILED" `
      -Message $cacheCreateWarning `
      -Context @{
      HashCachePath = $script:mcccCachePath
      GameModsDir = $GameModsDir
    } `
      -ExceptionType $_.Exception.GetType().FullName | Out-Null
    $script:mcccCacheEnabled = $false
  }

  $passedCount = 0
  if ($script:mcccCacheEnabled -and $null -ne $script:mcccCache -and $script:mcccCache.ContainsKey("passed") -and ($script:mcccCache["passed"] -is [hashtable])) {
    $passedCount = $script:mcccCache["passed"].Count
  }

  if ($script:mcccCacheEnabled -and $passedCount -gt 0 -and $candidateMods -and $candidateMods.Count -gt 0) {
    foreach ($mod in $candidateMods) {
      $hash = Get-Sha256LowerHex -Path $mod.FullName -Retries $HashCacheHashRetryCount -DelayMs $HashCacheHashRetryDelayMs
      if ([string]::IsNullOrWhiteSpace($hash)) { continue }
      if (Test-McccHashPassed -Cache $script:mcccCache -Sha256LowerHex $hash) {
        $script:mcccKnownGoodJarNameSet[$mod.Name.ToLowerInvariant()] = $hash
      }
    }

    if ($script:mcccKnownGoodJarNameSet.Count -gt 0) {
      $candidateMods = @($candidateMods | Where-Object { -not $script:mcccKnownGoodJarNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
      Write-Host ("Hash cache: skipping {0} previously passed mod(s)." -f $script:mcccKnownGoodJarNameSet.Count) -ForegroundColor Gray
    }
  }
}

# * Apply dependency-aware ordering (tiers by number of incoming dependents).
if ($UseDependencyAwareOrdering -and $candidateMods -and $candidateMods.Count -gt 0) {
  try {
    if ($DependencyAwareTier2MaxDependents -lt 0) { $DependencyAwareTier2MaxDependents = 0 }
    if ($DependencyAwareTier3MaxDependents -lt $DependencyAwareTier2MaxDependents) {
      $DependencyAwareTier3MaxDependents = $DependencyAwareTier2MaxDependents
    }
    if ($DependencyAwareExponentialMaxTier -lt 0) { $DependencyAwareExponentialMaxTier = 0 }
    if ($DependencyAwareExponentialMaxTier -gt 4) { $DependencyAwareExponentialMaxTier = 4 }
    if ($DependencyAwareQuickIsolateMaxTier -lt 0) { $DependencyAwareQuickIsolateMaxTier = 0 }
    if ($DependencyAwareQuickIsolateMaxTier -gt 4) { $DependencyAwareQuickIsolateMaxTier = 4 }

    $countMode = $DependencyAwareOrderingCountMode
    if ([string]::IsNullOrWhiteSpace($countMode)) { $countMode = "RequiredOnly" }

    $dependencyMap = $null
    if ($DependencyMapSource -ne "Internal") {
      $dependencyMap = Get-DependencyMapFromSource -ScanPath $GameModsDir
    }

    if ($dependencyMap) {
      Initialize-DependencyMapCache -DependencyMap $dependencyMap
      $depMap = Get-DependentModCountsFromDependencyMap -DependencyMap $dependencyMap -CountMode $countMode

      $mapScanPath = ""
      if ($dependencyMap.PSObject.Properties.Name -contains "Scan") {
        $mapScanPath = [string]$dependencyMap.Scan.Path
      }
      if (-not [string]::IsNullOrWhiteSpace($mapScanPath) -and (-not [string]::Equals($mapScanPath, $GameModsDir, [System.StringComparison]::OrdinalIgnoreCase))) {
        $scanPathMismatchWarning = ("Warning: dependency map scan path differs from GameModsDir: {0}" -f $mapScanPath)
        Write-Host $scanPathMismatchWarning -ForegroundColor Yellow
        Add-McccStageWarning `
          -Accumulator $candidatesStageResult `
          -Category "dependency_map" `
          -Code "DEPENDENCY_MAP_SCAN_PATH_MISMATCH" `
          -Message $scanPathMismatchWarning `
          -Context @{
          DependencyMapSource = $DependencyMapSource
          DependencyMapScanPath = $mapScanPath
          GameModsDir = $GameModsDir
        } | Out-Null
      } else {
        Write-Host ("Dependency map loaded from source: {0}" -f $DependencyMapSource) -ForegroundColor Gray
      }
    } else {
      if ($DependencyMapSource -ne "Internal") {
        $dependencyFallbackWarning = ("Warning: dependency map unavailable from source '{0}'. Falling back to internal parser." -f $DependencyMapSource)
        Write-Host $dependencyFallbackWarning -ForegroundColor Yellow
        Add-McccStageWarning `
          -Accumulator $candidatesStageResult `
          -Category "dependency_map" `
          -Code "DEPENDENCY_MAP_FALLBACK_INTERNAL" `
          -Message $dependencyFallbackWarning `
          -Context @{
          DependencyMapSource = $DependencyMapSource
          GameModsDir = $GameModsDir
        } | Out-Null
      }
      $depMap = Get-DependentModCountsByJarName -ModsDir $GameModsDir -CountMode $countMode
    }
    if ($depMap -and $depMap.Count -gt 0) {
      foreach ($jarKey in $depMap.Keys) {
        $depCount = [int]$depMap[$jarKey].DependentCount
        $known = [bool]$depMap[$jarKey].Known
        if (-not $known -and (-not [bool]$DependencyAwareTreatUnknownAsCore)) {
          $depCount = 0
          $known = $true
        }
        $script:dependencyAwareTierByJarName[$jarKey] = Get-DependencyAwareTier -DependentCount $depCount -Known $known
        $script:dependencyAwareStatsByJarName[$jarKey] = [pscustomobject]@{
          DependentCount = [int]$depCount
          Known = [bool]$known
        }
      }

      foreach ($mod in $candidateMods) {
        $jarKey = $mod.Name.ToLowerInvariant()
        $depCount = -1
        $known = $false
        if ($depMap.ContainsKey($jarKey)) {
          $depCount = [int]$depMap[$jarKey].DependentCount
          $known = [bool]$depMap[$jarKey].Known
        }

        if (-not $known -and (-not [bool]$DependencyAwareTreatUnknownAsCore)) {
          $depCount = 0
          $known = $true
        }

        $tier = Get-DependencyAwareTier -DependentCount $depCount -Known $known

        Add-Member -InputObject $mod -NotePropertyName DependentModCount -NotePropertyValue $depCount -Force
        Add-Member -InputObject $mod -NotePropertyName DependentModTier -NotePropertyValue $tier -Force
        Add-Member -InputObject $mod -NotePropertyName DependentModCountKnown -NotePropertyValue $known -Force
        if (-not $script:dependencyAwareStatsByJarName.ContainsKey($jarKey)) {
          $script:dependencyAwareStatsByJarName[$jarKey] = [pscustomobject]@{
            DependentCount = [int]$depCount
            Known = [bool]$known
          }
        }
      }

      $candidateMods = @($candidateMods | Sort-Object -Property `
          @{ Expression = { $_.DependentModTier }; Ascending = $true }, `
          @{ Expression = { $_.LastWriteTime }; Descending = $true }, `
          @{ Expression = { $_.Name }; Ascending = $true })
    } else {
      Write-Host "Dependency-aware ordering enabled, but dependency map is empty. Using date ordering." -ForegroundColor Gray
    }
  } catch {
    $dependencyOrderingWarning = ("Warning: dependency-aware ordering failed: {0}. Using date ordering." -f $_.Exception.Message)
    Write-Host $dependencyOrderingWarning -ForegroundColor Yellow
    Add-McccStageWarning `
      -Accumulator $candidatesStageResult `
      -Category "dependency_map" `
      -Code "DEPENDENCY_ORDERING_FAILED" `
      -Message $dependencyOrderingWarning `
      -Context @{
      DependencyMapSource = $DependencyMapSource
      GameModsDir = $GameModsDir
    } `
      -ExceptionType $_.Exception.GetType().FullName | Out-Null
  }
}

if (-not $candidateMods -or $candidateMods.Count -eq 0) {
  Write-Host "No jar mods found to test." -ForegroundColor Yellow
  Set-McccStageResult -StageResults $isolationStageResults -StageResult (Complete-McccStageAccumulator `
      -Accumulator $candidatesStageResult `
      -ExtraFields @{
      CandidateCount = 0
      DryRun = [bool]$DryRun
      ExitCode = 0
      StopReason = "no_jar_mods_found"
    })
  exit 0
}

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$gameLegacyRoot = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
$gameLegacyTempRoot = Join-Path -Path $gameLegacyRoot -ChildPath "temp"
$gameQuarantineDir = Join-Path -Path $gameLegacyTempRoot -ChildPath ("isolate-{0}" -f $runId)
$storageQuarantineDir = $null
if ($useStorage) {
  $storageLegacyRoot = Join-Path -Path $StorageModsDir -ChildPath $StorageLegacyFolderName
  $storageLegacyTempRoot = Join-Path -Path $storageLegacyRoot -ChildPath "temp"
  $storageQuarantineDir = Join-Path -Path $storageLegacyTempRoot -ChildPath ("isolate-{0}" -f $runId)
}

Write-Host ("Mods to test: {0}" -f $candidateMods.Count) -ForegroundColor Cyan
Write-Host ("Quarantine dir: {0}" -f $gameQuarantineDir) -ForegroundColor Gray
if ($useStorage) {
  Write-Host ("Storage quarantine dir: {0}" -f $storageQuarantineDir) -ForegroundColor Gray
}
Write-Host ("Isolation strategy: {0}" -f $effectiveIsolationStrategy) -ForegroundColor Gray
if ($effectiveIsolationStrategy -eq "Exponential") {
  Write-Host ("Binary refinement threshold: {0}" -f $BinaryLinearThreshold) -ForegroundColor Gray
}
if ($effectiveIsolationStrategy -eq "Hybrid") {
  $linearTierStart = if ($DependencyAwareExponentialMaxTier -lt 1) { 1 } else { [Math]::Min(4, $DependencyAwareExponentialMaxTier + 1) }
  Write-Host ("Hybrid tiers: exponential<= {0}, linear>= {1}" -f $DependencyAwareExponentialMaxTier, $linearTierStart) -ForegroundColor Gray
  if ($DependencyAwareExponentialMaxTier -gt 0) {
    Write-Host ("Binary refinement threshold: {0}" -f $BinaryLinearThreshold) -ForegroundColor Gray
  }
}

if ($DryRun) {
  foreach ($mod in $candidateMods) {
    if ($mod.PSObject.Properties.Name -contains "DependentModTier") {
      Write-Host ("Plan: {0} | tier={1} | dependents={2} | known={3} | mtime={4}" -f $mod.Name, $mod.DependentModTier, $mod.DependentModCount, $mod.DependentModCountKnown, $mod.LastWriteTime) -ForegroundColor Gray
    } else {
      Write-Host ("Plan: {0} ({1})" -f $mod.Name, $mod.LastWriteTime) -ForegroundColor Gray
    }
  }
  Write-Host "Dry run complete. No changes made." -ForegroundColor Green
  Set-McccStageResult -StageResults $isolationStageResults -StageResult (Complete-McccStageAccumulator `
      -Accumulator $candidatesStageResult `
      -ExtraFields @{
      CandidateCount = [int]$candidateMods.Count
      DryRun = $true
      ExitCode = 0
      StopReason = "dry_run"
    })
  exit 0
}

Set-McccStageResult -StageResults $isolationStageResults -StageResult (Complete-McccStageAccumulator `
    -Accumulator $candidatesStageResult `
    -ExtraFields @{
    CandidateCount = [int]$candidateMods.Count
    DryRun = $false
    RunId = $runId
    IsolationStrategy = $effectiveIsolationStrategy
    UseDependencyAwareOrdering = [bool]$UseDependencyAwareOrdering
    DependencyMapSource = $DependencyMapSource
  })
