if ($null -eq $checkCompatStageResults -or -not ($checkCompatStageResults -is [hashtable])) {
  $checkCompatStageResults = @{}
}
$reportingStageResult = New-McccStageAccumulator -Stage "CheckCompatibility.Reporting"
$stageDiagnosticSummary = Get-McccStageDiagnosticsSummary -StageResults $checkCompatStageResults

$report = [pscustomobject]@{
  minecraft = $mcVersion
  log = $primaryLogPath
  logs = $resolvedLogPaths
  dryRun = [bool]$DryRun
  deleteFromGameMods = [bool]$DeleteFromGameMods
  noLegacy = [bool]$NoLegacy
  gameLegacy = [bool]$GameLegacy
  effectiveDeleteFromGameMods = [bool]$deleteFromGame
  effectiveDeleteFromStorageMods = [bool]$deleteFromStorage
  treatNonFabricAsIncompatible = [bool]$TreatNonFabricAsIncompatible
  includeWarnMixinsAsIncompatible = [bool]$IncludeWarnMixinsAsIncompatible
  dependencyPriorityApplied = [bool]$dependencyPriorityApplied
  dependencyPrioritySource = $dependencyPrioritySourceUsed
  dependencyPriorityMapJsonPath = $dependencyPriorityMapJsonPath
  dependencyOrderingMode = $countMode
  dependencyTier2MaxDependents = [int]$DependencyAwareTier2MaxDependents
  dependencyTier3MaxDependents = [int]$DependencyAwareTier3MaxDependents
  fabricConflictDeferredModIds = @($fabricConflictDeferredModIds)
  count = $actions.Count
  items = $actions
  stageResults = $checkCompatStageResults
  stageWarnings = @($stageDiagnosticSummary.Warnings)
  stageErrors = @($stageDiagnosticSummary.Errors)
  diagnostics = @($stageDiagnosticSummary.Diagnostics)
}

if ($compatLogsEnabled) {
  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $compatReportDir = Join-Path -Path $projectRootPath -ChildPath "logs"
  New-DirectoryIfMissing -DirPath $compatReportDir
  $outPath = Join-Path -Path $compatReportDir -ChildPath ("compat-report-{0}.json" -f $timestamp)
  $report | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $outPath -Encoding UTF8

  Write-Host ""
  Write-Host ("Report: {0}" -f $outPath) -ForegroundColor Gray
  Write-Host ("Items: {0}" -f $actions.Count) -ForegroundColor Cyan
} else {
  Write-Host ""
  Write-Host ("Items: {0}" -f $actions.Count) -ForegroundColor Cyan
}

# * Compact console summary (mod ids only).
$handled = $actions | Where-Object { $_.status -eq "handled" } | Select-Object -ExpandProperty modId -Unique
if ($handled) {
  Write-Host ("Incompatible mods (handled): {0}" -f (($handled | Sort-Object) -join ", ")) -ForegroundColor Green
}

$unresolved = $actions | Where-Object { $_.status -eq "unresolved_in_game_mods" } | Select-Object -ExpandProperty modId -Unique
if ($unresolved) {
  Write-Host ("Incompatible mods (unresolved in game mods): {0}" -f (($unresolved | Sort-Object) -join ", ")) -ForegroundColor Yellow
}

$handledNonFabric = $actions | Where-Object { $_.status -eq "handled_non_fabric_by_filename" } | Select-Object -ExpandProperty jar -Unique
if ($handledNonFabric) {
  Write-Host ("Non-fabric mods (handled by filename): {0}" -f (($handledNonFabric | Sort-Object) -join ", ")) -ForegroundColor Green
}

$script:checkCompatExitCode = 0
$handledActions = @($actions | Where-Object { $_.status -in @("handled", "handled_non_fabric_by_filename") })
if ($actions.Count -gt 0 -and $handledActions.Count -eq 0) {
  $noRemovableMessage = "No removable mods found in game mods folder. Check missing dependencies or mod ids."
  Write-Host $noRemovableMessage -ForegroundColor Yellow
  Add-McccStageWarning `
    -Accumulator $reportingStageResult `
    -Category "reporting" `
    -Code "NO_REMOVABLE_MODS" `
    -Message $noRemovableMessage `
    -Context @{
    ActionCount = [int]$actions.Count
    HandledActionCount = [int]$handledActions.Count
  } | Out-Null
  $script:checkCompatExitCode = 3
}

Set-McccStageResult -StageResults $checkCompatStageResults -StageResult (Complete-McccStageAccumulator `
    -Accumulator $reportingStageResult `
    -ExtraFields @{
    ActionCount = [int]$actions.Count
    HandledActionCount = [int]$handledActions.Count
    ExitCode = [int]$script:checkCompatExitCode
  })
