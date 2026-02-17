if ($null -eq $checkCompatStageResults -or -not ($checkCompatStageResults -is [hashtable])) {
  $checkCompatStageResults = @{}
}
$evidenceStageResult = New-McccStageAccumulator -Stage "CheckCompatibility.Evidence"

$evidenceByModId = Get-IncompatibleModEvidenceFromLog -Lines $allLogLines -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
$nonFabricJarNames = Get-NonFabricJarNamesFromLog -Lines $allLogLines
if ($null -eq $nonFabricJarNames) {
  $nonFabricJarNames = @()
} else {
  $nonFabricJarNames = @($nonFabricJarNames)
}
if ($nonFabricJarNames.Count -gt 0) {
  $nonFabricJarNames = @($nonFabricJarNames | Select-Object -Unique)
}

$ignoreSet = @{}
foreach ($id in $IgnoreModIds) {
  $key = [string]$id
  if ([string]::IsNullOrWhiteSpace($key)) { continue }
  $ignoreSet[$key.ToLowerInvariant()] = $true
}
if ($ignoreSet.Count -gt 0) {
  $ignored = New-Object System.Collections.Generic.List[string]
  foreach ($id in @($evidenceByModId.Keys)) {
    if ($ignoreSet.ContainsKey($id)) {
      $null = $ignored.Add($id)
      $evidenceByModId.Remove($id)
    }
  }
  if ($ignored.Count -gt 0) {
    $ignoredLabel = @($ignored | Sort-Object -Unique)
    $ignoredMessage = ("Ignoring incompatible mod IDs: {0}" -f ($ignoredLabel -join ", "))
    Write-Host $ignoredMessage -ForegroundColor Gray
    Add-McccStageWarning `
      -Accumulator $evidenceStageResult `
      -Category "input_filtering" `
      -Code "IGNORED_INCOMPATIBLE_MOD_IDS" `
      -Message $ignoredMessage `
      -Context @{
      IgnoreModIds = @($IgnoreModIds)
      RemovedEvidenceModIds = @($ignoredLabel)
    } | Out-Null
  }
}

$patterns = Get-IncompatibleModPatternSet -IncludeWarnMixins ([bool]$IncludeWarnMixinsAsIncompatible)
$fabricConflictDeferredModIds = @()
$modConflictStats = @{}
$modReferrersByTarget = @{}

if ($evidenceByModId.Count -gt 0) {
  foreach ($modId in @($evidenceByModId.Keys)) {
    $rawEvidence = @($evidenceByModId[$modId])
    $uniqueLineSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $uniqueEvidence = New-Object System.Collections.Generic.List[string]
    foreach ($line in $rawEvidence) {
      $text = [string]$line
      if ([string]::IsNullOrWhiteSpace($text)) { continue }
      $normalized = Get-NormalizedEvidenceLine -Line $text
      if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
      if ($uniqueLineSet.Add($normalized)) {
        $uniqueEvidence.Add($text.Trim()) | Out-Null
      }
    }

    $evidenceByModId[$modId] = @($uniqueEvidence.ToArray())

    $fabricSuggestionCount = 0
    $incompatibleDetailCount = 0
    $referencesOtherSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($line in @($evidenceByModId[$modId])) {
      $text = [string]$line
      if ([string]::IsNullOrWhiteSpace($text)) { continue }
      if (
        [regex]::IsMatch($text, $patterns.FabricRemovePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -or
        [regex]::IsMatch($text, $patterns.FabricReplacePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -or
        [regex]::IsMatch($text, "(?i)\bFix:\s+add\s+\[")
      ) {
        $fabricSuggestionCount++
      }
      if ([regex]::IsMatch($text, $patterns.IncompatibleDetailPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $incompatibleDetailCount++
      }

      $mentionedIds = @(Get-ModIdSetFromLine -Line $text)
      foreach ($mentionedId in $mentionedIds) {
        if ([string]::IsNullOrWhiteSpace($mentionedId)) { continue }
        if ($mentionedId -eq $modId) { continue }
        $null = $referencesOtherSet.Add($mentionedId)
        if (-not $modReferrersByTarget.ContainsKey($mentionedId)) {
          $modReferrersByTarget[$mentionedId] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        $null = $modReferrersByTarget[$mentionedId].Add($modId)
      }
    }

    $evidenceCount = @($evidenceByModId[$modId]).Count
    $referencesOtherCount = $referencesOtherSet.Count
    $conflictScore = [int]($evidenceCount + ($incompatibleDetailCount * 2) + ($referencesOtherCount * 2))

    $modConflictStats[$modId] = [pscustomobject]@{
      EvidenceCount = [int]$evidenceCount
      FabricSuggestionCount = [int]$fabricSuggestionCount
      IncompatibleDetailCount = [int]$incompatibleDetailCount
      ReferencesOtherCount = [int]$referencesOtherCount
      ReferencedByOtherCount = 0
      ConflictScore = [int]$conflictScore
    }
  }

  foreach ($modId in @($modConflictStats.Keys)) {
    $referencedByCount = 0
    if ($modReferrersByTarget.ContainsKey($modId)) {
      $referencedByCount = [int]$modReferrersByTarget[$modId].Count
    }
    $stats = $modConflictStats[$modId]
    $modConflictStats[$modId] = [pscustomobject]@{
      EvidenceCount = [int]$stats.EvidenceCount
      FabricSuggestionCount = [int]$stats.FabricSuggestionCount
      IncompatibleDetailCount = [int]$stats.IncompatibleDetailCount
      ReferencesOtherCount = [int]$stats.ReferencesOtherCount
      ReferencedByOtherCount = [int]$referencedByCount
      ConflictScore = [int]$stats.ConflictScore
    }
  }
}

$hasFabricDialogSignal = Test-HasFabricDialogSignal -Lines $allLogLines
if ($hasFabricDialogSignal -and $evidenceByModId.Count -gt 1 -and $modConflictStats.Count -gt 0) {
  $deferred = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($modId in @($modConflictStats.Keys)) {
    $stats = $modConflictStats[$modId]
    $onlyFabricSuggestion = ($stats.EvidenceCount -gt 0 -and $stats.EvidenceCount -eq $stats.FabricSuggestionCount)
    if (-not $onlyFabricSuggestion) { continue }
    if ($stats.ReferencedByOtherCount -le 0) { continue }
    if (-not $modReferrersByTarget.ContainsKey($modId)) { continue }

    $maxReferrerScore = -1
    foreach ($referrer in @($modReferrersByTarget[$modId])) {
      if (-not $modConflictStats.ContainsKey($referrer)) { continue }
      $refScore = [int]$modConflictStats[$referrer].ConflictScore
      if ($refScore -gt $maxReferrerScore) {
        $maxReferrerScore = $refScore
      }
    }

    if ($maxReferrerScore -gt [int]$stats.ConflictScore) {
      $null = $deferred.Add($modId)
    }
  }

  if ($deferred.Count -gt 0 -and $deferred.Count -lt $evidenceByModId.Count) {
    $fabricConflictDeferredModIds = @($deferred | Sort-Object)
    foreach ($modId in $fabricConflictDeferredModIds) {
      if ($evidenceByModId.ContainsKey($modId)) {
        $null = $evidenceByModId.Remove($modId)
      }
    }
    $deferredMessage = ("Fabric conflict-priority deferred secondary mod IDs: {0}" -f ($fabricConflictDeferredModIds -join ", "))
    Write-Host $deferredMessage -ForegroundColor Gray
    Add-McccStageWarning `
      -Accumulator $evidenceStageResult `
      -Category "evidence_priority" `
      -Code "FABRIC_CONFLICT_PRIORITY_DEFERRED_MOD_IDS" `
      -Message $deferredMessage `
      -Context @{
      DeferredModIds = @($fabricConflictDeferredModIds)
      RemainingEvidenceModIdCount = [int]$evidenceByModId.Count
    } | Out-Null
  }
}

Set-McccStageResult -StageResults $checkCompatStageResults -StageResult (Complete-McccStageAccumulator `
    -Accumulator $evidenceStageResult `
    -ExtraFields @{
    EvidenceModIdCount = [int]$evidenceByModId.Count
    NonFabricJarCount = [int]$nonFabricJarNames.Count
    DeferredModIds = @($fabricConflictDeferredModIds)
  })
