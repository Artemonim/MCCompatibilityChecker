if ($null -eq $checkCompatStageResults -or -not ($checkCompatStageResults -is [hashtable])) {
  $checkCompatStageResults = @{}
}
$decisionStageResult = New-McccStageAccumulator -Stage "CheckCompatibility.Decision"

$deleteFromGame = [bool]$NoLegacy -or [bool]$DeleteFromGameMods -or (-not [bool]$GameLegacy)
$deleteFromStorage = [bool]$NoLegacy

$storageLegacyVersionDir = $null
if (-not $deleteFromStorage) {
  $storageLegacyDir = Join-Path -Path $StorageModsDir -ChildPath $StorageLegacyFolderName
  $storageLegacyVersionDir = Join-Path -Path $storageLegacyDir -ChildPath $mcVersion
}

$gameLegacyVersionDir = $null
if (-not $deleteFromGame) {
  $gameLegacyDir = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
  $gameLegacyVersionDir = Join-Path -Path $gameLegacyDir -ChildPath $mcVersion
}

$actions = New-Object System.Collections.Generic.List[object]

foreach ($modId in $orderedModIds) {
  $modIdVariants = @(Get-ModIdLookupVariantList -ModId $modId)
  $modIdVariantKeys = @($modIdVariants | Where-Object { -not [string]::Equals([string]$_, [string]$modId, [System.StringComparison]::OrdinalIgnoreCase) })

  $modPriority = $null
  if ($dependencyPriorityByModId.ContainsKey($modId)) {
    $modPriority = $dependencyPriorityByModId[$modId]
  }
  $priorityTier = if ($null -ne $modPriority) { [int]$modPriority.Tier } else { 0 }
  $priorityDependents = if ($null -ne $modPriority) { [int]$modPriority.DependentCount } else { -1 }
  $priorityKnown = if ($null -ne $modPriority) { [bool]$modPriority.Known } else { $false }
  $priorityDecision = if ($null -ne $modPriority) { [string]$modPriority.PriorityDecision } else { "" }
  $conflictScore = if ($null -ne $modPriority -and $modPriority.PSObject.Properties.Match("ConflictScore").Count -gt 0) { [int]$modPriority.ConflictScore } else { 0 }
  $evidenceCount = if ($null -ne $modPriority -and $modPriority.PSObject.Properties.Match("EvidenceCount").Count -gt 0) { [int]$modPriority.EvidenceCount } else { 0 }
  $fabricSuggestionCount = if ($null -ne $modPriority -and $modPriority.PSObject.Properties.Match("FabricSuggestionCount").Count -gt 0) { [int]$modPriority.FabricSuggestionCount } else { 0 }
  $incompatibleDetailCount = if ($null -ne $modPriority -and $modPriority.PSObject.Properties.Match("IncompatibleDetailCount").Count -gt 0) { [int]$modPriority.IncompatibleDetailCount } else { 0 }
  $referencesOtherCount = if ($null -ne $modPriority -and $modPriority.PSObject.Properties.Match("ReferencesOtherCount").Count -gt 0) { [int]$modPriority.ReferencesOtherCount } else { 0 }
  $referencedByOtherCount = if ($null -ne $modPriority -and $modPriority.PSObject.Properties.Match("ReferencedByOtherCount").Count -gt 0) { [int]$modPriority.ReferencedByOtherCount } else { 0 }

  $gameJarPaths = @()
  $resolvedByDirectGameId = $false
  if ($gameIdToJars.ContainsKey($modId)) {
    $gameJarPaths = @($gameIdToJars[$modId])
    if ($gameJarPaths.Count -gt 0) {
      $resolvedByDirectGameId = $true
    }
  }
  if ((-not $gameJarPaths -or $gameJarPaths.Count -eq 0) -and $modIdVariantKeys.Count -gt 0) {
    $variantGameJarPaths = New-Object System.Collections.Generic.List[string]
    foreach ($variantModId in @($modIdVariantKeys)) {
      $variantKey = [string]$variantModId
      if ([string]::IsNullOrWhiteSpace($variantKey)) { continue }
      if (-not $gameIdToJars.ContainsKey($variantKey)) { continue }
      foreach ($variantJarPath in @($gameIdToJars[$variantKey])) {
        $variantPath = [string]$variantJarPath
        if ([string]::IsNullOrWhiteSpace($variantPath)) { continue }
        $variantGameJarPaths.Add($variantPath) | Out-Null
      }
    }
    if ($variantGameJarPaths.Count -gt 0) {
      $gameJarPaths = @($variantGameJarPaths.ToArray() | Sort-Object -Unique)
    }
  }
  if ((-not $gameJarPaths -or $gameJarPaths.Count -eq 0)) {
    $gameJarPaths = @(Resolve-ModJarPathsByNestedFallback `
        -DirPath $GameModsDir `
        -ModId $modId `
        -ResolvedByModIdCache $nestedFallbackGamePathsByModId `
        -JarIdsByPathCache $nestedFallbackJarIdsByPathCache `
        -MaxNestedJarDepth $nestedFallbackMaxDepth)
  }
  if ((-not $gameJarPaths -or $gameJarPaths.Count -eq 0) -and $modIdVariantKeys.Count -gt 0) {
    $variantFallbackGameJarPaths = New-Object System.Collections.Generic.List[string]
    foreach ($variantModId in @($modIdVariantKeys)) {
      $variantKey = [string]$variantModId
      if ([string]::IsNullOrWhiteSpace($variantKey)) { continue }
      $variantResolved = @(Resolve-ModJarPathsByNestedFallback `
          -DirPath $GameModsDir `
          -ModId $variantKey `
          -ResolvedByModIdCache $nestedFallbackGamePathsByModId `
          -JarIdsByPathCache $nestedFallbackJarIdsByPathCache `
          -MaxNestedJarDepth $nestedFallbackMaxDepth)
      foreach ($variantJarPath in @($variantResolved)) {
        $variantPath = [string]$variantJarPath
        if ([string]::IsNullOrWhiteSpace($variantPath)) { continue }
        $variantFallbackGameJarPaths.Add($variantPath) | Out-Null
      }
    }
    if ($variantFallbackGameJarPaths.Count -gt 0) {
      $gameJarPaths = @($variantFallbackGameJarPaths.ToArray() | Sort-Object -Unique)
    }
  }
  if ((-not $gameJarPaths -or $gameJarPaths.Count -eq 0)) {
    $gameJarPaths = @(Resolve-GameJarPathsFromMixinEvidence `
        -ModId $modId `
        -ModsDir $GameModsDir `
        -EvidenceLines @($evidenceByModId[$modId]) `
        -JarMixinConfigEntryCache $jarMixinConfigEntryCache)
  }
  if ($gameJarPaths -and $gameJarPaths.Count -gt 1) {
    $gameJarSortProps = @(
      @{ Expression = { Get-LastWriteTimeSafe -Path $_ }; Descending = $true }
      @{ Expression = { $_ }; Ascending = $true }
    )
    $gameJarPaths = @($gameJarPaths | Sort-Object -Property $gameJarSortProps)
  }
  if ($resolvedByDirectGameId -and $gameJarPaths -and $gameJarPaths.Count -gt 1) {
    # * Multiple root jars with the same mod id are handled one-by-one per attempt.
    # * This keeps the isolation step minimal and avoids removing all duplicate versions at once.
    $gameJarPaths = @($gameJarPaths | Select-Object -First 1)
  }
  if ($gameJarPaths -and $gameJarPaths.Count -gt 1) {
    $gameJarPaths = @(Select-GameJarPathsByMixinEvidence `
        -ModId $modId `
        -CandidateJarPaths @($gameJarPaths) `
        -EvidenceLines @($evidenceByModId[$modId]) `
        -JarMixinConfigEntryCache $jarMixinConfigEntryCache)
  }

  $alreadyHandledGameJarPaths = New-Object System.Collections.Generic.List[string]
  if ($gameJarPaths -and $gameJarPaths.Count -gt 0) {
    $pendingGameJarPaths = New-Object System.Collections.Generic.List[string]
    foreach ($candidateGameJarPath in @($gameJarPaths)) {
      $candidatePath = [string]$candidateGameJarPath
      if ([string]::IsNullOrWhiteSpace($candidatePath)) { continue }
      if ($handledGameJarPathKeySet.Contains($candidatePath)) {
        $alreadyHandledGameJarPaths.Add($candidatePath) | Out-Null
        continue
      }
      $pendingGameJarPaths.Add($candidatePath) | Out-Null
    }
    $gameJarPaths = @($pendingGameJarPaths.ToArray())
  }

  if (-not $gameJarPaths -or $gameJarPaths.Count -eq 0) {
    if ($alreadyHandledGameJarPaths.Count -gt 0) {
      $alreadyHandledNames = @(
        $alreadyHandledGameJarPaths |
          ForEach-Object { [System.IO.Path]::GetFileName([string]$_) } |
          Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
          Sort-Object -Unique
      )
      $alreadyHandledLabel = if ($alreadyHandledNames.Count -gt 0) { $alreadyHandledNames -join ", " } else { "<unknown>" }
      $actions.Add([pscustomobject]@{
          modId = $modId
          status = "handled"
          evidence = @($evidenceByModId[$modId])
          game = @("already handled by previous mod action: $alreadyHandledLabel")
          storage = @()
          dependencyTier = $priorityTier
          dependentMods = $priorityDependents
          dependentModsKnown = $priorityKnown
          priorityDecision = $priorityDecision
          conflictScore = $conflictScore
          evidenceCount = $evidenceCount
          fabricSuggestionCount = $fabricSuggestionCount
          incompatibleDetailCount = $incompatibleDetailCount
          referencesOtherCount = $referencesOtherCount
          referencedByOtherCount = $referencedByOtherCount
        })
      continue
    }

    $actions.Add([pscustomobject]@{
        modId = $modId
        status = "unresolved_in_game_mods"
        evidence = @($evidenceByModId[$modId])
        game = @()
        storage = @()
        dependencyTier = $priorityTier
        dependentMods = $priorityDependents
        dependentModsKnown = $priorityKnown
        priorityDecision = $priorityDecision
        conflictScore = $conflictScore
        evidenceCount = $evidenceCount
        fabricSuggestionCount = $fabricSuggestionCount
        incompatibleDetailCount = $incompatibleDetailCount
        referencesOtherCount = $referencesOtherCount
        referencedByOtherCount = $referencedByOtherCount
      })
    Add-McccStageWarning `
      -Accumulator $decisionStageResult `
      -Category "mod_resolution" `
      -Code "UNRESOLVED_IN_GAME_MODS" `
      -Message "No removable mods found in game mods folder. Check missing dependencies or mod ids." `
      -Context @{
      ModId = $modId
      GameModsDir = $GameModsDir
      EvidenceCount = [int]@($evidenceByModId[$modId]).Count
      ModIdVariants = @($modIdVariantKeys)
    } | Out-Null
    continue
  }

  foreach ($gameJarPath in $gameJarPaths) {
    $gameFileName = [System.IO.Path]::GetFileName($gameJarPath)
    $storageJarPath = $null
    $gameHandledNow = $false
    $storageKey = $gameFileName.ToLowerInvariant()
    if ($storageFileNameToPath.ContainsKey($storageKey)) {
      $storageJarPath = $storageFileNameToPath[$storageKey]
    } elseif ($storageIdToJars.ContainsKey($modId) -and $storageIdToJars[$modId].Count -gt 0) {
      $storageJarPath = $storageIdToJars[$modId][0]
    } elseif ($modIdVariantKeys.Count -gt 0) {
      foreach ($variantModId in @($modIdVariantKeys)) {
        $variantKey = [string]$variantModId
        if ([string]::IsNullOrWhiteSpace($variantKey)) { continue }
        if (-not $storageIdToJars.ContainsKey($variantKey)) { continue }
        if ($storageIdToJars[$variantKey].Count -le 0) { continue }
        $storageJarPath = $storageIdToJars[$variantKey][0]
        break
      }
    } else {
      $storageFallbackJarPaths = @(Resolve-ModJarPathsByNestedFallback `
          -DirPath $StorageModsDir `
          -ModId $modId `
          -ResolvedByModIdCache $nestedFallbackStoragePathsByModId `
          -JarIdsByPathCache $nestedFallbackJarIdsByPathCache `
          -MaxNestedJarDepth $nestedFallbackMaxDepth)
      if ($storageFallbackJarPaths.Count -eq 0 -and $modIdVariantKeys.Count -gt 0) {
        $variantStorageFallbackPaths = New-Object System.Collections.Generic.List[string]
        foreach ($variantModId in @($modIdVariantKeys)) {
          $variantKey = [string]$variantModId
          if ([string]::IsNullOrWhiteSpace($variantKey)) { continue }
          $variantResolved = @(Resolve-ModJarPathsByNestedFallback `
              -DirPath $StorageModsDir `
              -ModId $variantKey `
              -ResolvedByModIdCache $nestedFallbackStoragePathsByModId `
              -JarIdsByPathCache $nestedFallbackJarIdsByPathCache `
              -MaxNestedJarDepth $nestedFallbackMaxDepth)
          foreach ($variantPath in @($variantResolved)) {
            $value = [string]$variantPath
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            $variantStorageFallbackPaths.Add($value) | Out-Null
          }
        }
        if ($variantStorageFallbackPaths.Count -gt 0) {
          $storageFallbackJarPaths = @($variantStorageFallbackPaths.ToArray() | Sort-Object -Unique)
        }
      }
      if ($storageFallbackJarPaths.Count -gt 0) {
        $storageNameMatched = @($storageFallbackJarPaths | Where-Object { [string]::Equals([System.IO.Path]::GetFileName([string]$_), $gameFileName, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($storageNameMatched.Count -gt 0) {
          $storageJarPath = $storageNameMatched[0]
        } else {
          $storageJarPath = $storageFallbackJarPaths[0]
        }
      }
    }

    $gameResult = $null
    if ($DryRun) {
        $gameResult = Move-OrDelete -SourcePath $gameJarPath -DestDir $gameLegacyVersionDir -DoDelete $deleteFromGame -IsDryRun $true
        if (-not [string]::IsNullOrWhiteSpace([string]$gameResult)) {
            $gameHandledNow = $true
        }
    } else {
        $moveResult = Move-CulpritToLegacyAndAppendLog `
            -JarName $gameFileName `
            -MinecraftVersion $mcVersion `
            -GameModsDir $GameModsDir `
            -StorageModsDir $StorageModsDir `
            -GameLegacyFolderName $GameLegacyFolderName `
            -StorageLegacyFolderName $StorageLegacyFolderName `
            -KeepCulpritInGameLegacy ([bool](-not $deleteFromGame)) `
            -GameSourcePath $gameJarPath `
            -StorageSourcePath $storageJarPath `
            -RemoveGameIfNotKeeping $true `
            -RequireStorageMoveForGameRemoval $false

        if ($moveResult.GameMoved) {
            $gameResult = if ($deleteFromGame) { "deleted: $gameJarPath" } else { "moved: $gameJarPath -> $gameLegacyVersionDir" }
            $gameHandledNow = $true
        }
    }

    if ($gameHandledNow) {
        $null = $handledGameJarPathKeySet.Add([string]$gameJarPath)
    }

    $storageResult = $null
    if ($DryRun) {
        if ($storageJarPath) {
            $storageResult = Move-OrDelete -SourcePath $storageJarPath -DestDir $storageLegacyVersionDir -DoDelete $deleteFromStorage -IsDryRun $true
        } else {
            $storageResult = ("not found in storage root for file '{0}' (modId '{1}')" -f $gameFileName, $modId)
            Add-McccStageWarning `
              -Accumulator $decisionStageResult `
              -Category "storage" `
              -Code "STORAGE_SOURCE_NOT_FOUND" `
              -Message $storageResult `
              -Context @{
              ModId = $modId
              JarName = $gameFileName
              StorageModsDir = $StorageModsDir
              DryRun = $true
            } | Out-Null
        }
    } else {
        # * Storage result is already handled by Move-CulpritToLegacyAndAppendLog above.
        if ($storageJarPath) {
            if ($null -ne $moveResult -and $moveResult.StorageMoved) {
                $storageResult = if ($deleteFromStorage) { "deleted: $storageJarPath" } else { "moved: $storageJarPath -> $storageLegacyVersionDir" }
            } else {
                $storageResult = "failed to move from storage"
                Add-McccStageWarning `
                  -Accumulator $decisionStageResult `
                  -Category "storage" `
                  -Code "STORAGE_MOVE_FAILED" `
                  -Message $storageResult `
                  -Context @{
                  ModId = $modId
                  JarName = $gameFileName
                  StorageSourcePath = $storageJarPath
                  StorageLegacyVersionDir = $storageLegacyVersionDir
                  DeleteFromStorage = [bool]$deleteFromStorage
                } | Out-Null
            }
        } else {
            $storageResult = ("not found in storage root for file '{0}' (modId '{1}')" -f $gameFileName, $modId)
            Add-McccStageWarning `
              -Accumulator $decisionStageResult `
              -Category "storage" `
              -Code "STORAGE_SOURCE_NOT_FOUND" `
              -Message $storageResult `
              -Context @{
              ModId = $modId
              JarName = $gameFileName
              StorageModsDir = $StorageModsDir
              DryRun = $false
            } | Out-Null
        }
    }

    $actions.Add([pscustomobject]@{
        modId = $modId
        status = "handled"
        evidence = @($evidenceByModId[$modId])
        game = @($gameResult)
        storage = @($storageResult)
        dependencyTier = $priorityTier
        dependentMods = $priorityDependents
        dependentModsKnown = $priorityKnown
        priorityDecision = $priorityDecision
        conflictScore = $conflictScore
        evidenceCount = $evidenceCount
        fabricSuggestionCount = $fabricSuggestionCount
        incompatibleDetailCount = $incompatibleDetailCount
        referencesOtherCount = $referencesOtherCount
        referencedByOtherCount = $referencedByOtherCount
      })
  }
}

if ($TreatNonFabricAsIncompatible -and $nonFabricJarNames -and $nonFabricJarNames.Count -gt 0) {
  $nonFabricOrder = New-Object System.Collections.Generic.List[object]
  foreach ($jarName in $nonFabricJarNames) {
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
    $gamePath = Join-Path -Path $GameModsDir -ChildPath $jarName
    $storagePath = Join-Path -Path $StorageModsDir -ChildPath $jarName
    $mtime = Get-LastWriteTimeSafe -Path $gamePath
    if ($mtime -eq [datetime]::MinValue) {
      $mtime = Get-LastWriteTimeSafe -Path $storagePath
    }
    $null = $nonFabricOrder.Add([pscustomobject]@{
        JarName = $jarName
        LastWriteTime = $mtime
      })
  }
  $nonFabricSortProps = @(
    @{ Expression = { $_.LastWriteTime }; Descending = $true }
    @{ Expression = { $_.JarName }; Ascending = $true }
  )
  $nonFabricJarNames = @($nonFabricOrder | Sort-Object -Property $nonFabricSortProps | ForEach-Object { $_.JarName })

  foreach ($jarName in $nonFabricJarNames) {
    $gamePath = Join-Path -Path $GameModsDir -ChildPath $jarName
    $storagePath = Join-Path -Path $StorageModsDir -ChildPath $jarName

    $gameResult = $null
    $storageResult = $null

    if ($DryRun) {
        if (Test-Path -LiteralPath $gamePath) {
            $gameResult = Move-OrDelete -SourcePath $gamePath -DestDir $gameLegacyVersionDir -DoDelete $deleteFromGame -IsDryRun $true
        } else {
            $gameResult = ("not present in game mods: {0}" -f $jarName)
        }
        if (Test-Path -LiteralPath $storagePath) {
            $storageResult = Move-OrDelete -SourcePath $storagePath -DestDir $storageLegacyVersionDir -DoDelete $deleteFromStorage -IsDryRun $true
        } else {
            $storageResult = ("not present in storage root: {0}" -f $jarName)
        }
    } else {
        $moveResult = Move-CulpritToLegacyAndAppendLog `
            -JarName $jarName `
            -MinecraftVersion $mcVersion `
            -GameModsDir $GameModsDir `
            -StorageModsDir $StorageModsDir `
            -GameLegacyFolderName $GameLegacyFolderName `
            -StorageLegacyFolderName $StorageLegacyFolderName `
            -KeepCulpritInGameLegacy ([bool](-not $deleteFromGame)) `
            -GameSourcePath $gamePath `
            -StorageSourcePath $storagePath `
            -RemoveGameIfNotKeeping $true `
            -RequireStorageMoveForGameRemoval $false

        if (Test-Path -LiteralPath $gamePath) {
            if ($moveResult.GameMoved) {
                $gameResult = if ($deleteFromGame) { "deleted: $gamePath" } else { "moved: $gamePath -> $gameLegacyVersionDir" }
            } else {
                $gameResult = "failed to move from game"
                Add-McccStageWarning `
                  -Accumulator $decisionStageResult `
                  -Category "game_mods" `
                  -Code "GAME_MOVE_FAILED_NON_FABRIC" `
                  -Message $gameResult `
                  -Context @{
                  JarName = $jarName
                  GameSourcePath = $gamePath
                  GameLegacyVersionDir = $gameLegacyVersionDir
                  DeleteFromGame = [bool]$deleteFromGame
                } | Out-Null
            }
        } else {
            $gameResult = ("not present in game mods: {0}" -f $jarName)
        }

        if (Test-Path -LiteralPath $storagePath) {
            if ($moveResult.StorageMoved) {
                $storageResult = if ($deleteFromStorage) { "deleted: $storagePath" } else { "moved: $storagePath -> $storageLegacyVersionDir" }
            } else {
                $storageResult = "failed to move from storage"
                Add-McccStageWarning `
                  -Accumulator $decisionStageResult `
                  -Category "storage" `
                  -Code "STORAGE_MOVE_FAILED_NON_FABRIC" `
                  -Message $storageResult `
                  -Context @{
                  JarName = $jarName
                  StorageSourcePath = $storagePath
                  StorageLegacyVersionDir = $storageLegacyVersionDir
                  DeleteFromStorage = [bool]$deleteFromStorage
                } | Out-Null
            }
        } else {
            $storageResult = ("not present in storage root: {0}" -f $jarName)
        }
    }

    $actions.Add([pscustomobject]@{
        modId = $null
        status = "handled_non_fabric_by_filename"
        evidence = @("non-fabric jar listed by Fabric loader")
        game = @($gameResult)
        storage = @($storageResult)
        jar = $jarName
      })
  }
}

if ($dependencyPriorityApplied -and $modIdOrder.Count -gt 0) {
  $preview = @($modIdOrder | Sort-Object -Property $modIdSortProps | Select-Object -First 8)
  if ($preview.Count -gt 0) {
    $previewLabel = $preview | ForEach-Object {
      "{0}(conflicts={1},tier={2},dependents={3})" -f $_.ModId, $_.ConflictScore, $_.PriorityTier, $_.PriorityDependentCount
    }
    Write-Host ("Dependency-priority order (top): {0}" -f ($previewLabel -join " -> ")) -ForegroundColor Gray
  }
}

$handledActionCount = @($actions | Where-Object { $_.status -eq "handled" }).Count
$unresolvedActionCount = @($actions | Where-Object { $_.status -eq "unresolved_in_game_mods" }).Count
$nonFabricActionCount = @($actions | Where-Object { $_.status -eq "handled_non_fabric_by_filename" }).Count

Set-McccStageResult -StageResults $checkCompatStageResults -StageResult (Complete-McccStageAccumulator `
    -Accumulator $decisionStageResult `
    -ExtraFields @{
    ActionCount = [int]$actions.Count
    HandledActionCount = [int]$handledActionCount
    UnresolvedActionCount = [int]$unresolvedActionCount
    NonFabricActionCount = [int]$nonFabricActionCount
  })
