if ($null -eq $checkCompatStageResults -or -not ($checkCompatStageResults -is [hashtable])) {
  $checkCompatStageResults = @{}
}
$modResolutionStageResult = New-McccStageAccumulator -Stage "CheckCompatibility.ModResolution"

# * Build mod id -> jar mapping for game mods dir.
$gameIdToJars = Build-ModIdToJarMap -DirPath $GameModsDir

# * For storage, prefer filename match, then fallback to id scan of root jars.
$storageRootJars = @(Get-McccJarFiles -RootPaths @($StorageModsDir) -SortBy "None" -EnumerationErrorAction "Stop")
$storageFileNameToPath = New-McccJarNamePathIndex -JarFilesOrPaths @($storageRootJars)
$storageIdToJars = Build-ModIdToJarMap -DirPath $StorageModsDir

# * Nested fallback caches to resolve unresolved mod IDs without building a full nested map.
$nestedFallbackMaxDepth = 1
$nestedFallbackJarIdsByPathCache = @{}
$nestedFallbackGamePathsByModId = @{}
$nestedFallbackStoragePathsByModId = @{}
$jarMixinConfigEntryCache = @{}

# * Keeps track of game jar paths already handled in this run to avoid duplicate moves
# * when multiple mod IDs resolve to the same physical jar.
$handledGameJarPathKeySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

$dependencyPriorityApplied = $false
$dependencyPrioritySourceUsed = "none"
$dependencyPriorityMapJsonPath = ""
$dependencyPriorityByJarName = @{}
$dependencyPriorityByModId = @{}

if ($DependencyAwareTier2MaxDependents -lt 0) { $DependencyAwareTier2MaxDependents = 0 }
if ($DependencyAwareTier3MaxDependents -lt $DependencyAwareTier2MaxDependents) {
  $DependencyAwareTier3MaxDependents = $DependencyAwareTier2MaxDependents
}

$countMode = $DependencyAwareOrderingCountMode
if ([string]::IsNullOrWhiteSpace($countMode)) { $countMode = "RequiredOnly" }

$dependencyMap = $null
if ($DependencyMapSource -ne "Internal") {
  $dependencyMap = Get-DependencyMapFromSource -ScanPath $GameModsDir
}

$depCountMap = @{}
if ($dependencyMap) {
  Initialize-DependencyMapCache -DependencyMap $dependencyMap
  $depCountMap = Get-DependentModCountsFromDependencyMap -DependencyMap $dependencyMap -CountMode $countMode
  $dependencyPrioritySourceUsed = $DependencyMapSource
} else {
  if ($DependencyMapSource -ne "Internal") {
    $dependencyFallbackMessage = ("Warning: dependency map unavailable from source '{0}'. Falling back to internal parser." -f $DependencyMapSource)
    Write-Host $dependencyFallbackMessage -ForegroundColor Yellow
    Add-McccStageWarning `
      -Accumulator $modResolutionStageResult `
      -Category "dependency_map" `
      -Code "DEPENDENCY_MAP_FALLBACK_INTERNAL" `
      -Message $dependencyFallbackMessage `
      -Context @{
      DependencyMapSource = $DependencyMapSource
      GameModsDir = $GameModsDir
    } | Out-Null
  }
  $depCountMap = Get-DependentModCountsByJarName -ModsDir $GameModsDir -CountMode $countMode
  $dependencyPrioritySourceUsed = "Internal"
}

$dependencyDependentsByModId = @{}
if ($dependencyMap -and ($dependencyMap.PSObject.Properties.Name -contains "Dependencies")) {
  foreach ($edge in @($dependencyMap.Dependencies)) {
    if ($null -eq $edge) { continue }
    $depId = [string]$edge.DependencyId
    $fromModId = [string]$edge.FromModId
    if ([string]::IsNullOrWhiteSpace($depId) -or [string]::IsNullOrWhiteSpace($fromModId)) { continue }

    $isRequired = $true
    if ($edge.PSObject.Properties.Name -contains "IsRequired") {
      $isRequired = [bool]$edge.IsRequired
    }
    if ($countMode -eq "RequiredOnly" -and (-not $isRequired)) { continue }

    $depKey = $depId.ToLowerInvariant()
    $fromKey = $fromModId.ToLowerInvariant()
    if ([string]::Equals($depKey, $fromKey, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    if (-not $dependencyDependentsByModId.ContainsKey($depKey)) {
      $dependencyDependentsByModId[$depKey] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    $null = $dependencyDependentsByModId[$depKey].Add($fromKey)
  }
}

if ($DependencyMapSource -eq "File") {
  $dependencyPriorityMapJsonPath = $DependencyMapJsonPath
  if ([string]::IsNullOrWhiteSpace($dependencyPriorityMapJsonPath)) {
    $dependencyPriorityMapJsonPath = Join-Path -Path $projectRootPath -ChildPath "reports\jar-dependency-map.json"
  }
} elseif ($DependencyMapSource -eq "Tool") {
  $mapOutDir = $DependencyMapOutDir
  if ([string]::IsNullOrWhiteSpace($mapOutDir)) {
    $mapOutDir = Join-Path -Path $projectRootPath -ChildPath "reports"
  }
  $dependencyPriorityMapJsonPath = Join-Path -Path $mapOutDir -ChildPath "jar-dependency-map.json"
}
if (-not [string]::IsNullOrWhiteSpace($dependencyPriorityMapJsonPath) -and (Test-Path -LiteralPath $dependencyPriorityMapJsonPath)) {
  $dependencyPriorityMapJsonPath = (Resolve-Path -LiteralPath $dependencyPriorityMapJsonPath).Path
}

$gameRootJars = @(Get-McccJarFiles -RootPaths @($GameModsDir) -SortBy "None" -EnumerationErrorAction "Stop")
foreach ($jar in $gameRootJars) {
  $jarKey = $jar.Name.ToLowerInvariant()
  $depCount = -1
  $known = $false
  if ($depCountMap.ContainsKey($jarKey)) {
    $depCount = [int]$depCountMap[$jarKey].DependentCount
    $known = [bool]$depCountMap[$jarKey].Known
  }
  if (-not $known -and (-not [bool]$DependencyAwareTreatUnknownAsCore)) {
    $depCount = 0
    $known = $true
  }
  $tier = Get-DependencyAwareTier -DependentCount $depCount -Known $known
  $dependencyPriorityByJarName[$jarKey] = [pscustomobject]@{
    Tier = [int]$tier
    DependentCount = [int]$depCount
    Known = [bool]$known
    DependentCountSort = if ($depCount -ge 0) { [int]$depCount } else { [int]::MaxValue }
  }
}

if ($dependencyPriorityByJarName.Count -gt 0) {
  $dependencyPriorityApplied = $true
  $sourceLabel = if ([string]::IsNullOrWhiteSpace($dependencyPriorityMapJsonPath)) { $dependencyPrioritySourceUsed } else { "{0} ({1})" -f $dependencyPrioritySourceUsed, $dependencyPriorityMapJsonPath }
  Write-Host ("Dependency-priority ordering enabled. Source: {0}" -f $sourceLabel) -ForegroundColor Gray
}

$modIdOrder = New-Object System.Collections.Generic.List[object]
foreach ($modId in $evidenceByModId.Keys) {
  $conflictScore = 0
  $evidenceCount = 0
  $fabricSuggestionCount = 0
  $incompatibleDetailCount = 0
  $referencesOtherCount = 0
  $referencedByOtherCount = 0
  if ($modConflictStats.ContainsKey($modId)) {
    $conflictStats = $modConflictStats[$modId]
    $conflictScore = [int]$conflictStats.ConflictScore
    $evidenceCount = [int]$conflictStats.EvidenceCount
    $fabricSuggestionCount = [int]$conflictStats.FabricSuggestionCount
    $incompatibleDetailCount = [int]$conflictStats.IncompatibleDetailCount
    $referencesOtherCount = [int]$conflictStats.ReferencesOtherCount
    $referencedByOtherCount = [int]$conflictStats.ReferencedByOtherCount
  }

  $latestWrite = [datetime]::MinValue
  $bestTier = if ([bool]$DependencyAwareTreatUnknownAsCore) { 4 } else { 1 }
  $bestDependentCount = -1
  $bestDependentSort = [int]::MaxValue
  $bestKnown = $false
  $bestFound = $false
  $bestMtime = [datetime]::MinValue

  if ($gameIdToJars.ContainsKey($modId)) {
    foreach ($jarPath in @($gameIdToJars[$modId])) {
      $mtime = Get-LastWriteTimeSafe -Path $jarPath
      if ($mtime -gt $latestWrite) { $latestWrite = $mtime }

      $jarName = [System.IO.Path]::GetFileName($jarPath).ToLowerInvariant()
      $tier = if ([bool]$DependencyAwareTreatUnknownAsCore) { 4 } else { 1 }
      $depCount = -1
      $known = $false
      $depSort = [int]::MaxValue
      if ($dependencyPriorityByJarName.ContainsKey($jarName)) {
        $jarPriority = $dependencyPriorityByJarName[$jarName]
        $tier = [int]$jarPriority.Tier
        $depCount = [int]$jarPriority.DependentCount
        $known = [bool]$jarPriority.Known
        $depSort = [int]$jarPriority.DependentCountSort
      }

      if ((-not $bestFound) -or $tier -lt $bestTier -or ($tier -eq $bestTier -and $depSort -lt $bestDependentSort) -or ($tier -eq $bestTier -and $depSort -eq $bestDependentSort -and $mtime -gt $bestMtime)) {
        $bestTier = $tier
        $bestDependentCount = $depCount
        $bestDependentSort = $depSort
        $bestKnown = $known
        $bestFound = $true
        $bestMtime = $mtime
      }
    }
  }
  $priorityDecision = if ($bestKnown) {
    "selected by dependency priority: tier={0}, dependents={1}" -f $bestTier, $bestDependentCount
  } else {
    "selected by fallback order: dependency metadata unavailable"
  }

  $dependencyPriorityByModId[$modId] = [pscustomobject]@{
    Tier = [int]$bestTier
    DependentCount = [int]$bestDependentCount
    Known = [bool]$bestKnown
    DependentCountSort = [int]$bestDependentSort
    PriorityDecision = $priorityDecision
    ConflictScore = [int]$conflictScore
    EvidenceCount = [int]$evidenceCount
    FabricSuggestionCount = [int]$fabricSuggestionCount
    IncompatibleDetailCount = [int]$incompatibleDetailCount
    ReferencesOtherCount = [int]$referencesOtherCount
    ReferencedByOtherCount = [int]$referencedByOtherCount
  }

  $null = $modIdOrder.Add([pscustomobject]@{
      ModId = $modId
      LastWriteTime = $latestWrite
      ConflictScore = [int]$conflictScore
      EvidenceCount = [int]$evidenceCount
      PriorityTier = [int]$bestTier
      PriorityDependentCount = [int]$bestDependentCount
      PriorityDependentCountSort = [int]$bestDependentSort
      PriorityKnown = [bool]$bestKnown
      PriorityDecision = $priorityDecision
    })
}
$modIdSortProps = @(
  @{ Expression = { $_.ConflictScore }; Descending = $true }
  @{ Expression = { $_.EvidenceCount }; Descending = $true }
  @{ Expression = { $_.PriorityTier }; Ascending = $true }
  @{ Expression = { $_.PriorityDependentCountSort }; Ascending = $true }
  @{ Expression = { $_.LastWriteTime }; Descending = $true }
  @{ Expression = { $_.ModId }; Ascending = $true }
)
$orderedModIds = @($modIdOrder | Sort-Object -Property $modIdSortProps | ForEach-Object { $_.ModId })

Set-McccStageResult -StageResults $checkCompatStageResults -StageResult (Complete-McccStageAccumulator `
    -Accumulator $modResolutionStageResult `
    -ExtraFields @{
    OrderedModIdCount = [int]$orderedModIds.Count
    DependencyPriorityApplied = [bool]$dependencyPriorityApplied
    DependencyPrioritySource = $dependencyPrioritySourceUsed
    DependencyPriorityMapJsonPath = $dependencyPriorityMapJsonPath
    DependencyTieredJarCount = [int]$dependencyPriorityByJarName.Count
    DependencyDependentModIdCount = [int]$dependencyDependentsByModId.Count
  })
