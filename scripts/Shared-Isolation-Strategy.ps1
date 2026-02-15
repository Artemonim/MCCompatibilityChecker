function Resolve-IsolationStrategyContext {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  if ($null -ne $Context) { return $Context }

  $launcherContext = Resolve-IsolationLauncherContext

  $storageModsDir = ""
  $storageModsVar = Get-Variable -Name "StorageModsDir" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $storageModsVar) { $storageModsDir = [string]$storageModsVar.Value }

  $pinnedSetVar = Get-Variable -Name "pinnedJarNameSet" -Scope Script -ErrorAction SilentlyContinue
  $pinnedSet = if ($null -ne $pinnedSetVar -and $pinnedSetVar.Value -is [hashtable]) { [hashtable]$pinnedSetVar.Value } else { @{} }

  $movedItemsVar = Get-Variable -Name "movedItems" -Scope Script -ErrorAction SilentlyContinue
  $movedItemsLocal = if ($null -ne $movedItemsVar -and $movedItemsVar.Value) { $movedItemsVar.Value } else { New-Object System.Collections.Generic.List[object] }

  $movedSetVar = Get-Variable -Name "movedJarNameSet" -Scope Script -ErrorAction SilentlyContinue
  $movedSetLocal = if ($null -ne $movedSetVar -and $movedSetVar.Value -is [hashtable]) { [hashtable]$movedSetVar.Value } else { @{} }

  $phaseVar = Get-Variable -Name "phase" -Scope Script -ErrorAction SilentlyContinue
  $lastOutcomeVar = Get-Variable -Name "lastOutcomeHandleId" -Scope Script -ErrorAction SilentlyContinue
  $mcVersionVar = Get-Variable -Name "mcVersionForLegacy" -Scope Script -ErrorAction SilentlyContinue
  $activeSignatureVar = Get-Variable -Name "activeBaselineSignature" -Scope Script -ErrorAction SilentlyContinue
  $activeEvidenceVar = Get-Variable -Name "activeBaselineEvidenceKey" -Scope Script -ErrorAction SilentlyContinue
  $lastPinnedVar = Get-Variable -Name "lastBaselinePinnedKey" -Scope Script -ErrorAction SilentlyContinue
  $tierVar = Get-Variable -Name "currentDependencyTier" -Scope Script -ErrorAction SilentlyContinue
  $blockedVar = Get-Variable -Name "blockedByDependency" -Scope Script -ErrorAction SilentlyContinue
  $baselineVar = Get-Variable -Name "baselineSucceeded" -Scope Script -ErrorAction SilentlyContinue
  $blockedMissingVar = Get-Variable -Name "blockedDependencyMissing" -Scope Script -ErrorAction SilentlyContinue
  $blockedRequiringVar = Get-Variable -Name "blockedDependencyRequiring" -Scope Script -ErrorAction SilentlyContinue
  $blockedContextVar = Get-Variable -Name "blockedDependencyContext" -Scope Script -ErrorAction SilentlyContinue

  $useStorageLocal = $false
  $useStorageVar = Get-Variable -Name "useStorage" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $useStorageVar) { $useStorageLocal = [bool]$useStorageVar.Value }

  $logPathLocal = ""
  $logPathVar = Get-Variable -Name "LogPath" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $logPathVar) { $logPathLocal = [string]$logPathVar.Value }

  $logMaxAgeMinutesLocal = 30
  $logMaxAgeVar = Get-Variable -Name "LogMaxAgeMinutes" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $logMaxAgeVar) { $logMaxAgeMinutesLocal = [int]$logMaxAgeVar.Value }

  $logReadRetryCountLocal = 5
  $logReadRetryCountVar = Get-Variable -Name "LogReadRetryCount" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $logReadRetryCountVar) { $logReadRetryCountLocal = [int]$logReadRetryCountVar.Value }

  $logReadRetryDelayMsLocal = 500
  $logReadRetryDelayVar = Get-Variable -Name "LogReadRetryDelayMs" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $logReadRetryDelayVar) { $logReadRetryDelayMsLocal = [int]$logReadRetryDelayVar.Value }

  $skipGameLogsLocal = $false
  $skipGameLogsVar = Get-Variable -Name "SkipGameLogs" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $skipGameLogsVar) { $skipGameLogsLocal = [bool]$skipGameLogsVar.Value }

  $logSinceSkewSecondsLocal = 120
  $logSinceSkewVar = Get-Variable -Name "LogSinceSkewSeconds" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $logSinceSkewVar) { $logSinceSkewSecondsLocal = [int]$logSinceSkewVar.Value }

  $errorSignatureLineLimitLocal = 2
  $errorSignatureVar = Get-Variable -Name "ErrorSignatureLineLimit" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $errorSignatureVar) { $errorSignatureLineLimitLocal = [int]$errorSignatureVar.Value }

  $includeWarnMixinsLocal = $false
  $includeWarnMixinsVar = Get-Variable -Name "IncludeWarnMixinsAsIncompatible" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $includeWarnMixinsVar) { $includeWarnMixinsLocal = [bool]$includeWarnMixinsVar.Value }

  $ignoreModListForSignatureChangeLocal = $true
  $ignoreModListVar = Get-Variable -Name "IgnoreModListForSignatureChange" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $ignoreModListVar) { $ignoreModListForSignatureChangeLocal = [bool]$ignoreModListVar.Value }

  $logPostRunDelaySecondsLocal = 3
  $logPostRunDelayVar = Get-Variable -Name "LogPostRunDelaySeconds" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $logPostRunDelayVar) { $logPostRunDelaySecondsLocal = [int]$logPostRunDelayVar.Value }

  $binaryLinearThresholdLocal = 8
  $binaryLinearThresholdVar = Get-Variable -Name "BinaryLinearThreshold" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $binaryLinearThresholdVar) { $binaryLinearThresholdLocal = [int]$binaryLinearThresholdVar.Value }

  $dependencyAwareExponentialMaxTierLocal = 2
  $dependencyAwareExponentialMaxTierVar = Get-Variable -Name "DependencyAwareExponentialMaxTier" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $dependencyAwareExponentialMaxTierVar) { $dependencyAwareExponentialMaxTierLocal = [int]$dependencyAwareExponentialMaxTierVar.Value }

  $dependencyAwareTreatUnknownAsCoreLocal = $true
  $dependencyAwareTreatUnknownAsCoreVar = Get-Variable -Name "DependencyAwareTreatUnknownAsCore" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $dependencyAwareTreatUnknownAsCoreVar) { $dependencyAwareTreatUnknownAsCoreLocal = [bool]$dependencyAwareTreatUnknownAsCoreVar.Value }

  $moveRetryCountLocal = 15
  $moveRetryCountVar = Get-Variable -Name "MoveRetryCount" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $moveRetryCountVar) { $moveRetryCountLocal = [int]$moveRetryCountVar.Value }

  $moveRetryDelayMsLocal = 1000
  $moveRetryDelayVar = Get-Variable -Name "MoveRetryDelayMs" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $moveRetryDelayVar) { $moveRetryDelayMsLocal = [int]$moveRetryDelayVar.Value }

  $gameQuarantineDirLocal = ""
  $gameQuarantineDirVar = Get-Variable -Name "gameQuarantineDir" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $gameQuarantineDirVar) { $gameQuarantineDirLocal = [string]$gameQuarantineDirVar.Value }

  $storageQuarantineDirLocal = ""
  $storageQuarantineDirVar = Get-Variable -Name "storageQuarantineDir" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $storageQuarantineDirVar) { $storageQuarantineDirLocal = [string]$storageQuarantineDirVar.Value }

  $forceRestoreLocal = $false
  $forceRestoreVar = Get-Variable -Name "ForceRestore" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $forceRestoreVar) { $forceRestoreLocal = [bool]$forceRestoreVar.Value }

  return [pscustomobject]@{
    Paths = [pscustomobject]@{
      GameModsDir = $launcherContext.Paths.GameModsDir
      StorageModsDir = $storageModsDir
      LauncherExePath = $launcherContext.Paths.LauncherExePath
      LogPath = $logPathLocal
    }
    Launcher = $launcherContext.Launcher
    Ui = $launcherContext.Ui
    Timeouts = $launcherContext.Timeouts
    Process = $launcherContext.Process
    Cache = $launcherContext.Cache
    Log = [pscustomobject]@{
      LogPath = $logPathLocal
      LogMaxAgeMinutes = $logMaxAgeMinutesLocal
      LogReadRetryCount = $logReadRetryCountLocal
      LogReadRetryDelayMs = $logReadRetryDelayMsLocal
      SkipGameLogs = [bool]$skipGameLogsLocal
      LogSinceSkewSeconds = $logSinceSkewSecondsLocal
    }
    Strategy = [pscustomobject]@{
      ErrorSignatureLineLimit = $errorSignatureLineLimitLocal
      IncludeWarnMixinsAsIncompatible = [bool]$includeWarnMixinsLocal
      IgnoreModListForSignatureChange = [bool]$ignoreModListForSignatureChangeLocal
      LogPostRunDelaySeconds = $logPostRunDelaySecondsLocal
      BinaryLinearThreshold = $binaryLinearThresholdLocal
      DependencyAwareExponentialMaxTier = $dependencyAwareExponentialMaxTierLocal
      DependencyAwareTreatUnknownAsCore = [bool]$dependencyAwareTreatUnknownAsCoreLocal
    }
    Quarantine = [pscustomobject]@{
      UseStorage = $useStorageLocal
      MoveRetryCount = $moveRetryCountLocal
      MoveRetryDelayMs = $moveRetryDelayMsLocal
      GameQuarantineDir = $gameQuarantineDirLocal
      StorageQuarantineDir = $storageQuarantineDirLocal
      MovedItems = $movedItemsLocal
      MovedJarNameSet = $movedSetLocal
      ForceRestore = [bool]$forceRestoreLocal
    }
    State = [pscustomobject]@{
      Phase = if ($null -ne $phaseVar) { [string]$phaseVar.Value } else { "" }
      LastOutcomeHandleId = if ($null -ne $lastOutcomeVar) { [long]$lastOutcomeVar.Value } else { 0 }
      McVersionForLegacy = if ($null -ne $mcVersionVar) { [string]$mcVersionVar.Value } else { "unknown" }
      ActiveBaselineSignature = if ($null -ne $activeSignatureVar) { [string]$activeSignatureVar.Value } else { "" }
      ActiveBaselineEvidenceKey = if ($null -ne $activeEvidenceVar) { [string]$activeEvidenceVar.Value } else { "" }
      LastBaselinePinnedKey = if ($null -ne $lastPinnedVar) { [string]$lastPinnedVar.Value } else { "" }
      CurrentDependencyTier = if ($null -ne $tierVar) { [int]$tierVar.Value } else { 0 }
      PinnedJarNameSet = $pinnedSet
      BlockedByDependency = if ($null -ne $blockedVar) { [bool]$blockedVar.Value } else { $false }
      BaselineSucceeded = if ($null -ne $baselineVar) { [bool]$baselineVar.Value } else { $false }
      BlockedDependencyMissing = if ($null -ne $blockedMissingVar -and $blockedMissingVar.Value) { @($blockedMissingVar.Value) } else { @() }
      BlockedDependencyRequiring = if ($null -ne $blockedRequiringVar -and $blockedRequiringVar.Value) { @($blockedRequiringVar.Value) } else { @() }
      BlockedDependencyContext = if ($null -ne $blockedContextVar) { [string]$blockedContextVar.Value } else { "" }
    }
  }
}

function Set-IsolationStrategyPhase {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Context,
    [Parameter(Mandatory = $true)]
    [string]$Phase
  )

  if ($null -eq $Context -or $null -eq $Context.State) { return }
  $Context.State.Phase = $Phase
  $phaseVar = Get-Variable -Name "phase" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $phaseVar) { $script:phase = $Phase }
}

function Set-IsolationStrategyCurrentDependencyTier {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Context,
    [Parameter(Mandatory = $true)]
    [int]$Tier
  )

  if ($null -eq $Context -or $null -eq $Context.State) { return }
  $Context.State.CurrentDependencyTier = $Tier
  $tierVar = Get-Variable -Name "currentDependencyTier" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $tierVar) { $script:currentDependencyTier = $Tier }
}

function Get-PinnedJarNameKey {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $ctx = Resolve-IsolationStrategyContext -Context $Context
  $pinnedSet = $ctx.State.PinnedJarNameSet
  if (-not $pinnedSet -or $pinnedSet.Count -eq 0) { return "" }
  return (($pinnedSet.Keys | Sort-Object) -join "|")
}

# * Runs a single isolation probe and returns whether the test group matches the baseline issue.
function Invoke-IsolationProbe {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$TestJarNames,
    [Parameter(Mandatory = $true)]
    [string]$BaselineSignature,
    [Parameter(Mandatory = $true)]
    [string]$BaselineEvidenceKey,
    [Parameter(Mandatory = $false)]
    [string]$PhasePrefix = "isolation_probe",
    [Parameter(Mandatory = $false)]
    [string[]]$PinnedJarNames = @(),
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $ctx = Resolve-IsolationStrategyContext -Context $Context
  $state = $ctx.State
  $ui = $ctx.Ui
  $timeouts = $ctx.Timeouts
  $strategy = $ctx.Strategy

  Update-QuarantineState -DesiredJarNames $TestJarNames -PinnedJarNames $PinnedJarNames -Context $ctx

  if ([string]::IsNullOrWhiteSpace($PhasePrefix)) {
    $PhasePrefix = "isolation_probe"
  }

  $ignoreHandles = @()
  if ($state.LastOutcomeHandleId -ne 0) {
    $ignoreHandles = @($state.LastOutcomeHandleId)
  }

  $attemptStart = Get-Date
  Set-IsolationStrategyPhase -Context $ctx -Phase ("{0}_invoke_launch" -f $PhasePrefix)
  $outcome = Invoke-ConfiguredLaunchAttempt -IgnoreHandleIds $ignoreHandles -Context $ctx

  if ($outcome.Type -ne "FabricDialog") {
    $fabricWindowNow = Select-WindowByTitlePattern -Patterns $ui.FabricWindowTitlePatterns
    if ($null -ne $fabricWindowNow) {
      Write-Host ("Detected Fabric dialog after outcome: {0}" -f $fabricWindowNow.Title) -ForegroundColor Yellow
      $outcome = [pscustomobject]@{
        Type = "FabricDialog"
        Window = $fabricWindowNow
      }
    }
  }

  if ($outcome.Type -ne "FabricDialog" -and $outcome.Type -ne "CrashDialog") {
    $crashWindowNow = Select-WindowByTitlePattern -Patterns $ui.CrashWindowTitlePatterns
    if ($null -ne $crashWindowNow) {
      Write-Host ("Detected crash dialog after outcome: {0}" -f $crashWindowNow.Title) -ForegroundColor Yellow
      $outcome = [pscustomobject]@{
        Type = "CrashDialog"
        Window = $crashWindowNow
      }
    }
  }

  Write-Host ("Outcome: {0}" -f $outcome.Type) -ForegroundColor $(if ($outcome.Type -eq "Timeout") { "Green" } else { "Yellow" })

  if ($outcome.Type -ne "Timeout" -and $null -ne $outcome.Window) {
    Set-IsolationStrategyPhase -Context $ctx -Phase ("{0}_close_outcome_window" -f $PhasePrefix)
    $state.LastOutcomeHandleId = Close-OutcomeWindowWithExtraDialog -Outcome $outcome `
      -DelaySeconds $timeouts.CrashCloseDelaySeconds `
      -OffsetX $ui.CrashCloseClickOffsetX `
      -OffsetY $ui.CrashCloseClickOffsetY `
      -CloseExtraFabricDialogs $true `
      -Context $ctx
  }

  if ($outcome.Type -eq "Timeout") {
    # * Game survived the probe window and is still running. Kill it so
    # * the next iteration can move JAR files and launch a fresh instance.
    Set-IsolationStrategyPhase -Context $ctx -Phase ("{0}_stop_game_after_timeout" -f $PhasePrefix)
    [void](Stop-ConfiguredGameProcess -StartedAfter $attemptStart -Context $ctx)
    [void](Wait-ConfiguredGameExit -StartedAfter $attemptStart -Context $ctx)

    $launchConfigKey = ""
    if ($outcome | Get-Member -Name "LaunchConfigKey" -MemberType NoteProperty, Property) {
      $launchConfigKey = [string]$outcome.LaunchConfigKey
    }
    if (-not [string]::IsNullOrWhiteSpace($launchConfigKey)) {
      Register-SessionLaunchConfigSuccess -ConfigKey $launchConfigKey -Context $ctx
    }
  } else {
    Set-IsolationStrategyPhase -Context $ctx -Phase ("{0}_wait_game_exit" -f $PhasePrefix)
    [void](Wait-ConfiguredGameExit -StartedAfter $attemptStart -Context $ctx)
  }

  if ($outcome.Type -eq "FabricDialog") {
    Start-Sleep -Seconds $strategy.LogPostRunDelaySeconds
    Set-IsolationStrategyPhase -Context $ctx -Phase ("{0}_read_dependency_logs" -f $PhasePrefix)
    $snapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $attemptStart -Context $ctx
    $requiringModIds = @(Get-FabricRequiringModId -Lines $snapshot.Lines) |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    $missingDepIds = @(Get-FabricMissingDependencyId -Lines $snapshot.Lines) |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    Wait-ConfiguredLauncherInteractive -Context $ctx
    return [pscustomobject]@{
      Outcome = $outcome
      GroupMatches = $false
      Mode = "DependencyDialog"
      RequiringModIds = @($requiringModIds)
      MissingDepIds = @($missingDepIds)
    }
  }

  $groupMatches = $false
  if ($outcome.Type -eq "Timeout") {
    $groupMatches = $true
  } else {
    Start-Sleep -Seconds $strategy.LogPostRunDelaySeconds
    Set-IsolationStrategyPhase -Context $ctx -Phase ("{0}_read_logs" -f $PhasePrefix)
    $snapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $attemptStart -Context $ctx

    if ($state.McVersionForLegacy -eq "unknown") {
      $state.McVersionForLegacy = Get-MinecraftVersionFromLog -Lines $snapshot.Lines
    }

    $signature = Get-ErrorSignature -Lines $snapshot.Lines `
      -MaxLines $strategy.ErrorSignatureLineLimit `
      -IncludeWarnMixins ([bool]$strategy.IncludeWarnMixinsAsIncompatible)
    $evidenceKey = Get-ErrorEvidenceKey -Lines $snapshot.Lines -MaxLines $strategy.ErrorSignatureLineLimit

    Write-Verbose ("Signature: {0}" -f $signature)
    $signatureChanged = Test-SignatureChanged -Baseline $BaselineSignature -Current $signature `
      -BaselineEvidenceKey $BaselineEvidenceKey -CurrentEvidenceKey $evidenceKey `
      -IgnoreModsWhenEvidencePresent ([bool]$strategy.IgnoreModListForSignatureChange)
    if ($signatureChanged) {
      Start-Sleep -Milliseconds 750
      $confirmSnapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $attemptStart -Context $ctx
      $confirmSignature = Get-ErrorSignature -Lines $confirmSnapshot.Lines `
        -MaxLines $strategy.ErrorSignatureLineLimit `
        -IncludeWarnMixins ([bool]$strategy.IncludeWarnMixinsAsIncompatible)
      $confirmEvidenceKey = Get-ErrorEvidenceKey -Lines $confirmSnapshot.Lines -MaxLines $strategy.ErrorSignatureLineLimit
      if (-not (Test-SignatureChanged -Baseline $BaselineSignature -Current $confirmSignature `
          -BaselineEvidenceKey $BaselineEvidenceKey -CurrentEvidenceKey $confirmEvidenceKey `
          -IgnoreModsWhenEvidencePresent ([bool]$strategy.IgnoreModListForSignatureChange))) {
        Write-Verbose "Signature change not confirmed; treating as unchanged."
        $signatureChanged = $false
      }
    }
    $groupMatches = $signatureChanged
  }

  Wait-ConfiguredLauncherInteractive -Context $ctx

  return [pscustomobject]@{
    Outcome = $outcome
    GroupMatches = $groupMatches
    Mode = "Ok"
  }
}

# * Handles Fabric dependency dialogs by restoring removed deps and quick-isolating requiring mods.
function Invoke-FabricDependencyRecovery {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$RequiringModIds,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$MissingDepIds,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$RemovedJarNames,
    [Parameter(Mandatory = $true)]
    [hashtable]$PinnedJarNameSet,
    [Parameter(Mandatory = $true)]
    [hashtable]$ProtectedJarNameSet,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $ctx = Resolve-IsolationStrategyContext -Context $Context
  $state = $ctx.State
  $paths = $ctx.Paths
  $quarantine = $ctx.Quarantine

  $changes = $false
  $pinnedAdded = New-Object System.Collections.Generic.List[string]
  $protectedAdded = New-Object System.Collections.Generic.List[string]

  $requiringArr = @($RequiringModIds)
  $missingArr = @($MissingDepIds)
  $requiringLabel = if ($requiringArr.Count -gt 0) { $requiringArr -join ", " } else { "<none>" }
  $missingLabel = if ($missingArr.Count -gt 0) { $missingArr -join ", " } else { "<none>" }
  Write-Host ("Fabric dialog info. Requiring mods: {0}; Missing deps: {1}" -f $requiringLabel, $missingLabel) -ForegroundColor Gray

  $removedArr = @($RemovedJarNames)
  if ($missingArr.Count -gt 0 -and $removedArr.Count -gt 0) {
    foreach ($jarName in $removedArr) {
      if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
      $key = $jarName.ToLowerInvariant()
      if ($ProtectedJarNameSet.ContainsKey($key)) { continue }

      $removedItem = Get-MovedItemByJarName -JarName $jarName -Context $ctx
      if ($null -eq $removedItem) { continue }

      $removedJarProvides = @()
      if ($null -ne $removedItem.GameQuarantine -and (Test-Path -LiteralPath $removedItem.GameQuarantine)) {
        $removedJarProvides = Get-FabricModIdsFromJar -JarPath $removedItem.GameQuarantine
      }
      $removedJarProvidesArr = @($removedJarProvides)

      $isLikelyRemovedDep = $false
      if ($removedJarProvidesArr.Count -gt 0) {
        $isLikelyRemovedDep = Test-AnyIdOverlap -IdsA $removedJarProvidesArr -IdsB $missingArr
      }
      if (-not $isLikelyRemovedDep) {
        $isLikelyRemovedDep = Test-JarNameMatchesAnyId -JarName $jarName -Ids $missingArr -AllowTokenMatch:$false
      }
      if (-not $isLikelyRemovedDep) { continue }

      Write-Host ("Fabric missing dependency '{0}' appears caused by removing '{1}'. Restoring dependency." -f ($missingArr -join ", "), $jarName) -ForegroundColor Cyan

      if ($null -ne $removedItem.GameQuarantine -and (Test-Path -LiteralPath $removedItem.GameQuarantine)) {
        [void](Restore-FromQuarantine -SourcePath $removedItem.GameQuarantine -DestDir $paths.GameModsDir -IsDryRun $false -AllowOverwrite $true)
        $removedItem.GameQuarantine = $null
      }
      if ($quarantine.UseStorage -and $null -ne $removedItem.StorageQuarantine -and (Test-Path -LiteralPath $removedItem.StorageQuarantine)) {
        [void](Restore-FromQuarantine -SourcePath $removedItem.StorageQuarantine -DestDir $paths.StorageModsDir -IsDryRun $false -AllowOverwrite $true)
        $removedItem.StorageQuarantine = $null
      }
      if ($quarantine.MovedJarNameSet.ContainsKey($jarName)) {
        $null = $quarantine.MovedJarNameSet.Remove($jarName)
      }

      $ProtectedJarNameSet[$key] = $jarName
      $protectedAdded.Add($jarName)
      $changes = $true
    }
  }

  if ($requiringArr.Count -gt 0) {
    Write-Host ("Fabric dialog detected. Quick-isolating requiring mods: {0}" -f ($requiringArr -join ", ")) -ForegroundColor Cyan
    $searchDirs = @($paths.GameModsDir)
    if ($quarantine.GameQuarantineDir) { $searchDirs += $quarantine.GameQuarantineDir }
    if ($quarantine.StorageQuarantineDir) { $searchDirs += $quarantine.StorageQuarantineDir }
    $culpritJars = Find-ModJarByIdBestEffort -Dirs $searchDirs -ModIds $requiringArr -AllowTokenFallback:$false
    $culpritJars = Select-QuickIsolateJarsByTier -Jars $culpritJars -Context "dependency dialog" -MaxResults 1
    if ($culpritJars -and $culpritJars.Count -gt 0 -and $ProtectedJarNameSet.Count -gt 0) {
      $culpritJars = @($culpritJars | Where-Object {
          -not $ProtectedJarNameSet.ContainsKey($_.Name.ToLowerInvariant())
        })
    }
    if ($culpritJars -and $culpritJars.Count -gt 0) {
      foreach ($cj in $culpritJars) {
        if ($quarantine.MovedJarNameSet.ContainsKey($cj.Name)) { continue }

        Write-Host ("Quick-isolating: {0}" -f $cj.Name) -ForegroundColor Cyan
        Set-IsolationStrategyPhase -Context $ctx -Phase "quick_isolate_move"
        $qDest = Move-ToQuarantine -SourcePath $cj.FullName -DestDir $quarantine.GameQuarantineDir -IsDryRun $false -Retries $quarantine.MoveRetryCount -DelayMs $quarantine.MoveRetryDelayMs
        if ($null -ne $qDest) {
          [void](Add-MovedItemRecord -JarName $cj.Name -GameSource $cj.FullName -GameQuarantine $qDest -StorageSource $null -StorageQuarantine $null -Context $ctx)
          $PinnedJarNameSet[$cj.Name.ToLowerInvariant()] = $cj.Name
          $state.PinnedJarNameSet[$cj.Name.ToLowerInvariant()] = $cj.Name
          $pinnedAdded.Add($cj.Name)
          $changes = $true
        }
      }
    } else {
      Write-Host ("Warning: could not resolve or filtered requiring mod jar(s) for ids: {0}. Continuing isolation." -f ($requiringArr -join ", ")) -ForegroundColor Yellow
    }
  }

  return [pscustomobject]@{
    Changes = $changes
    PinnedAdded = @($pinnedAdded.ToArray() | Sort-Object -Unique)
    ProtectedAdded = @($protectedAdded.ToArray() | Sort-Object -Unique)
  }
}

function Invoke-BinaryIsolation {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Mods,
    [Parameter(Mandatory = $true)]
    [string]$BaselineSignature,
    [Parameter(Mandatory = $true)]
    [string]$BaselineEvidenceKey,
    [Parameter(Mandatory = $false)]
    [string[]]$PinnedJarNames = @(),
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $ctx = Resolve-IsolationStrategyContext -Context $Context
  $strategy = $ctx.Strategy

  $pinnedJarNameSet = @{}
  foreach ($name in $PinnedJarNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $pinnedJarNameSet[$name.ToLowerInvariant()] = $name
  }
  $protectedJarNameSet = @{}

  $remaining = @($Mods)
  if ($pinnedJarNameSet.Count -gt 0) {
    $remaining = @($remaining | Where-Object { -not $pinnedJarNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
  }
  if (-not $remaining -or $remaining.Count -eq 0) {
    return [pscustomobject]@{
      Mode = "ContinueLinear"
      Remaining = @()
      Reason = "empty"
    }
  }

  # * Pre-check: remove ALL candidate mods at once. If the crash signature
  # * does not change, the culprit is not in this set and binary search is futile.
  if ($remaining.Count -gt 1) {
    $allNames = @($remaining | ForEach-Object { $_.Name })
    $pinnedJarNames = @($pinnedJarNameSet.Values)
    Write-Host ("Binary Isolation: verifying {0} candidate(s) removed at once..." -f $allNames.Count) -ForegroundColor Gray
    $verifyResult = Invoke-IsolationProbe -TestJarNames $allNames `
      -BaselineSignature $BaselineSignature `
      -BaselineEvidenceKey $BaselineEvidenceKey `
      -PhasePrefix "binary_verify_all" `
      -PinnedJarNames $pinnedJarNames `
      -Context $ctx
    if ($verifyResult.Mode -eq "DependencyDialog") {
      Write-Host "Dependency dialog during verify-all probe. Proceeding to binary refinement." -ForegroundColor Yellow
    } elseif (-not [bool]$verifyResult.GroupMatches) {
      Write-Host "Removing all candidates did not change the crash. Culprit is not in this set." -ForegroundColor Yellow
      $pinnedJarNames = @($pinnedJarNameSet.Values)
      Update-QuarantineState -DesiredJarNames @() -PinnedJarNames $pinnedJarNames -Context $ctx
      return [pscustomobject]@{
        Mode = "ContinueLinear"
        Remaining = @()
        Reason = "all_removed_no_change"
      }
    }
  }

  $attemptIndex = 0
  while ($remaining.Count -gt $strategy.BinaryLinearThreshold) {
    if ($remaining.Count -le 1) { break }

    $attemptIndex++
    $halfCount = [Math]::Ceiling($remaining.Count / 2)
    # ! Avoid Select-Object -First which can emit PipelineStoppedException under $ErrorActionPreference='Stop'.
    $testGroup = @($remaining[0..($halfCount - 1)])
    $otherGroup = @($remaining[$halfCount..($remaining.Count - 1)])
    if (-not $otherGroup -or $otherGroup.Count -eq 0) { break }

    Write-Host ("Binary Isolation attempt {0}: testing {1} mod(s)" -f $attemptIndex, $testGroup.Count) -ForegroundColor Cyan

    $testNames = @($testGroup | ForEach-Object { $_.Name })
    $pinnedJarNames = @($pinnedJarNameSet.Values)
    $probeResult = Invoke-IsolationProbe -TestJarNames $testNames `
      -BaselineSignature $BaselineSignature `
      -BaselineEvidenceKey $BaselineEvidenceKey `
      -PhasePrefix "binary_attempt" `
      -PinnedJarNames $pinnedJarNames `
      -Context $ctx

    if ($probeResult.Mode -eq "DependencyDialog") {
      $recovery = Invoke-FabricDependencyRecovery -RequiringModIds $probeResult.RequiringModIds `
        -MissingDepIds $probeResult.MissingDepIds `
        -RemovedJarNames $testNames `
        -PinnedJarNameSet $pinnedJarNameSet `
        -ProtectedJarNameSet $protectedJarNameSet `
        -Context $ctx
      if ($recovery.Changes) {
        $pinnedJarNames = @($pinnedJarNameSet.Values)
        Update-QuarantineState -DesiredJarNames @() -PinnedJarNames $pinnedJarNames -Context $ctx
        $remaining = @($remaining | Where-Object {
            $key = $_.Name.ToLowerInvariant()
            -not $pinnedJarNameSet.ContainsKey($key) -and -not $protectedJarNameSet.ContainsKey($key)
          })
        if (-not $remaining -or $remaining.Count -eq 0) {
          return [pscustomobject]@{
            Mode = "ContinueLinear"
            Remaining = @()
            Reason = "dependency_recovery_empty"
          }
        }
        continue
      }
      Write-Host "Warning: dependency dialog detected but no Recovery actions were taken. Continuing binary refinement." -ForegroundColor Yellow
      $groupMatches = $false
    } else {
      $groupMatches = [bool]$probeResult.GroupMatches
    }

    if ($groupMatches) {
      $remaining = $testGroup
    } else {
      $remaining = $otherGroup
    }
  }

  $pinnedJarNames = @($pinnedJarNameSet.Values)
  Update-QuarantineState -DesiredJarNames @() -PinnedJarNames $pinnedJarNames -Context $ctx
  return [pscustomobject]@{
    Mode = "ContinueLinear"
    Remaining = $remaining
    Reason = "threshold"
  }
}

function Invoke-ExponentialIsolation {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Mods,
    [Parameter(Mandatory = $true)]
    [string]$BaselineSignature,
    [Parameter(Mandatory = $true)]
    [string]$BaselineEvidenceKey,
    [Parameter(Mandatory = $false)]
    [string[]]$PinnedJarNames = @(),
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $ctx = Resolve-IsolationStrategyContext -Context $Context

  $pinnedJarNameSet = @{}
  foreach ($name in $PinnedJarNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $pinnedJarNameSet[$name.ToLowerInvariant()] = $name
  }
  $protectedJarNameSet = @{}

  $remaining = @($Mods)
  if ($pinnedJarNameSet.Count -gt 0) {
    $remaining = @($remaining | Where-Object { -not $pinnedJarNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
  }
  if (-not $remaining -or $remaining.Count -eq 0) {
    return [pscustomobject]@{
      Mode = "ContinueLinear"
      Remaining = @()
      Reason = "empty"
    }
  }

  $totalCount = $remaining.Count
  $probeMax = [Math]::Floor($totalCount / 2)
  if ($probeMax -lt 1) { $probeMax = 1 }
  if ($probeMax -gt $totalCount) { $probeMax = $totalCount }

  Write-Host ("Exponential probe max: {0}" -f $probeMax) -ForegroundColor Gray

  $probeSize = 1
  $previousSize = 0
  $attemptIndex = 0
  $selectedChunk = $null
  $selectedReason = "exponential_miss"

  while ($probeSize -le $probeMax) {
    if ($probeSize -gt $totalCount) { $probeSize = $totalCount }

    $attemptIndex++
    # ! Avoid Select-Object -First which can emit PipelineStoppedException under $ErrorActionPreference='Stop'.
    $testGroup = @($remaining[0..($probeSize - 1)])
    if (-not $testGroup -or $testGroup.Count -eq 0) { break }

    Write-Host ("Exponential Isolation attempt {0}: testing {1} mod(s)" -f $attemptIndex, $testGroup.Count) -ForegroundColor Cyan

    $testNames = @($testGroup | ForEach-Object { $_.Name })
    $pinnedJarNames = @($pinnedJarNameSet.Values)
    $probeResult = Invoke-IsolationProbe -TestJarNames $testNames `
      -BaselineSignature $BaselineSignature `
      -BaselineEvidenceKey $BaselineEvidenceKey `
      -PhasePrefix "exponential_attempt" `
      -PinnedJarNames $pinnedJarNames `
      -Context $ctx

    if ($probeResult.Mode -eq "DependencyDialog") {
      $recovery = Invoke-FabricDependencyRecovery -RequiringModIds $probeResult.RequiringModIds `
        -MissingDepIds $probeResult.MissingDepIds `
        -RemovedJarNames $testNames `
        -PinnedJarNameSet $pinnedJarNameSet `
        -ProtectedJarNameSet $protectedJarNameSet `
        -Context $ctx
      if ($recovery.Changes) {
        $pinnedJarNames = @($pinnedJarNameSet.Values)
        Update-QuarantineState -DesiredJarNames @() -PinnedJarNames $pinnedJarNames -Context $ctx
        $remaining = @($remaining | Where-Object {
            $key = $_.Name.ToLowerInvariant()
            -not $pinnedJarNameSet.ContainsKey($key) -and -not $protectedJarNameSet.ContainsKey($key)
          })
        $totalCount = $remaining.Count
        if ($totalCount -eq 0) {
          return [pscustomobject]@{
            Mode = "ContinueLinear"
            Remaining = @()
            Reason = "dependency_recovery_empty"
          }
        }
        $probeMax = [Math]::Floor($totalCount / 2)
        if ($probeMax -lt 1) { $probeMax = 1 }
        if ($probeMax -gt $totalCount) { $probeMax = $totalCount }
        $probeSize = 1
        $previousSize = 0
        Write-Host ("Exponential isolation restarted after dependency Recovery. Remaining: {0}" -f $totalCount) -ForegroundColor Gray
        continue
      }
      Write-Host "Warning: dependency dialog detected but no Recovery actions were taken. Continuing exponential probing." -ForegroundColor Yellow
      $previousSize = $probeSize
      $probeSize = $probeSize * 2
      continue
    }

    if ([bool]$probeResult.GroupMatches) {
      $chunkSize = $probeSize - $previousSize
      if ($chunkSize -le 0) { $chunkSize = $probeSize }
      $selectedChunk = @($remaining | Select-Object -Skip $previousSize -First $chunkSize)
      $selectedReason = "exponential_match"
      break
    }

    $previousSize = $probeSize
    $probeSize = $probeSize * 2
  }

  if ($null -eq $selectedChunk) {
    $selectedChunk = @($remaining | Select-Object -Skip $previousSize)
  }

  if (-not $selectedChunk -or $selectedChunk.Count -eq 0) {
    $pinnedJarNames = @($pinnedJarNameSet.Values)
    Update-QuarantineState -DesiredJarNames @() -PinnedJarNames $pinnedJarNames -Context $ctx
    return [pscustomobject]@{
      Mode = "ContinueLinear"
      Remaining = @()
      Reason = "empty"
    }
  }

  if ($selectedReason -eq "exponential_match") {
    Write-Host ("Exponential Isolation selected last chunk: {0} mod(s)" -f $selectedChunk.Count) -ForegroundColor Gray
  } else {
    Write-Host ("Exponential Isolation selected remaining group: {0} mod(s)" -f $selectedChunk.Count) -ForegroundColor Gray
  }

  $pinnedJarNames = @($pinnedJarNameSet.Values)
  $binaryResult = Invoke-BinaryIsolation -Mods $selectedChunk `
    -BaselineSignature $BaselineSignature `
    -BaselineEvidenceKey $BaselineEvidenceKey `
    -PinnedJarNames $pinnedJarNames `
    -Context $ctx
  return [pscustomobject]@{
    Mode = $binaryResult.Mode
    Remaining = $binaryResult.Remaining
    Reason = ("{0}/{1}" -f $selectedReason, $binaryResult.Reason)
  }
}

# * Refreshes the baseline signature before linear isolation phases.
function Invoke-LinearBaselineRefresh {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PhasePrefix,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $ctx = Resolve-IsolationStrategyContext -Context $Context
  $state = $ctx.State
  $ui = $ctx.Ui
  $timeouts = $ctx.Timeouts
  $strategy = $ctx.Strategy

  Write-Host ("Refreshing baseline signature for {0}." -f $PhasePrefix) -ForegroundColor Gray

  $attemptStart = Get-Date
  Set-IsolationStrategyPhase -Context $ctx -Phase ("{0}_baseline_invoke_launch" -f $PhasePrefix)
  $baselineOutcomeObj = Invoke-ConfiguredLaunchAttempt -IgnoreHandleIds @() -Context $ctx

  $baselineOutcome = $baselineOutcomeObj.Type
  Write-Host ("{0} baseline outcome: {1}" -f $PhasePrefix, $baselineOutcome) -ForegroundColor $(if ($baselineOutcome -eq "Timeout") { "Green" } else { "Yellow" })

  if ($baselineOutcome -ne "Timeout") {
    if ($null -ne $baselineOutcomeObj.Window) {
      Set-IsolationStrategyPhase -Context $ctx -Phase ("{0}_baseline_close_outcome_window" -f $PhasePrefix)
      $state.LastOutcomeHandleId = Close-OutcomeWindowWithExtraDialog -Outcome $baselineOutcomeObj `
        -DelaySeconds $timeouts.CrashCloseDelaySeconds `
        -OffsetX $ui.CrashCloseClickOffsetX `
        -OffsetY $ui.CrashCloseClickOffsetY `
        -CloseExtraFabricDialogs $false `
        -Context $ctx
    }
    Set-IsolationStrategyPhase -Context $ctx -Phase ("{0}_baseline_wait_game_exit" -f $PhasePrefix)
    [void](Wait-ConfiguredGameExit -StartedAfter $attemptStart -Context $ctx)
  } else {
    # ! If the baseline issue does not reproduce at phase entry, isolation results are unreliable.
    # ! Stop early to prevent moving a random mod to Legacy.
    $launchConfigKey = ""
    if ($baselineOutcomeObj | Get-Member -Name "LaunchConfigKey" -MemberType NoteProperty, Property) {
      $launchConfigKey = [string]$baselineOutcomeObj.LaunchConfigKey
    }
    if (-not [string]::IsNullOrWhiteSpace($launchConfigKey)) {
      Register-SessionLaunchConfigSuccess -ConfigKey $launchConfigKey -Context $ctx
    }
    Write-Host ("Warning: baseline issue not reproduced in {0}. Stopping Isolation to avoid false culprit selection." -f $PhasePrefix) -ForegroundColor Yellow
    Wait-ConfiguredLauncherInteractive -Context $ctx
    return [pscustomobject]@{
      Outcome = $baselineOutcome
      ShouldContinue = $false
    }
  }

  Wait-ConfiguredLauncherInteractive -Context $ctx

  Start-Sleep -Seconds $strategy.LogPostRunDelaySeconds
  Set-IsolationStrategyPhase -Context $ctx -Phase ("{0}_baseline_read_logs" -f $PhasePrefix)
  $baselineSnapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $attemptStart -Context $ctx
  if (Test-DependencyDialogBlock -Context ("{0} baseline" -f $PhasePrefix) -Lines $baselineSnapshot.Lines -StateContext $ctx) {
    return [pscustomobject]@{
      Outcome = $baselineOutcome
      ShouldContinue = $false
    }
  }
  $state.ActiveBaselineSignature = Get-ErrorSignature -Lines $baselineSnapshot.Lines `
    -MaxLines $strategy.ErrorSignatureLineLimit `
    -IncludeWarnMixins ([bool]$strategy.IncludeWarnMixinsAsIncompatible)
  $state.ActiveBaselineEvidenceKey = Get-ErrorEvidenceKey -Lines $baselineSnapshot.Lines -MaxLines $strategy.ErrorSignatureLineLimit

  if ([string]::IsNullOrWhiteSpace($state.ActiveBaselineSignature)) {
    Write-Host ("{0} baseline signature is empty. Error change detection may be limited." -f $PhasePrefix) -ForegroundColor Yellow
  } else {
    Write-Verbose ("{0} baseline signature: {1}" -f $PhasePrefix, $state.ActiveBaselineSignature)
  }

  $state.LastBaselinePinnedKey = Get-PinnedJarNameKey -Context $ctx

  return [pscustomobject]@{
    Outcome = $baselineOutcome
    ShouldContinue = $true
  }
}

# * Runs linear isolation on the provided mod list.
function Invoke-LinearIsolation {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Mods,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $ctx = Resolve-IsolationStrategyContext -Context $Context
  $state = $ctx.State
  $paths = $ctx.Paths
  $quarantine = $ctx.Quarantine
  $ui = $ctx.Ui
  $timeouts = $ctx.Timeouts
  $strategy = $ctx.Strategy

  if (-not $Mods -or $Mods.Count -eq 0) {
    return [pscustomobject]@{
      Found = $false
      CulpritJarNames = @()
      StopReason = ""
    }
  }

  $attemptIndex = 0
  foreach ($mod in $Mods) {
    # * Mods can be moved by quick-isolate before their turn in the main loop.
    # * Skip silently to avoid noisy "not moved" warnings and inconsistent attempt behavior.
    if (-not (Test-Path -LiteralPath $mod.FullName)) {
      Write-Verbose ("Skipping already removed or missing mod: {0}" -f $mod.Name)
      continue
    }
    if ($quarantine.MovedJarNameSet.ContainsKey($mod.Name)) {
      Write-Verbose ("Skipping already quarantined mod: {0}" -f $mod.Name)
      continue
    }

    $attemptIndex++
    Write-Host ("Isolation attempt {0}: removing {1}" -f $attemptIndex, $mod.Name) -ForegroundColor Cyan

    Set-IsolationStrategyPhase -Context $ctx -Phase "move_to_quarantine"
    $gameDest = Move-ToQuarantine -SourcePath $mod.FullName -DestDir $quarantine.GameQuarantineDir -IsDryRun $false -Retries $quarantine.MoveRetryCount -DelayMs $quarantine.MoveRetryDelayMs
    if ($null -eq $gameDest) {
      Write-Verbose ("Skipping not moved (already removed or missing): {0}" -f $mod.FullName)
      continue
    } else {
      Write-Verbose ("Moved: {0} -> {1}" -f $mod.Name, $gameDest)
    }
    $storageDest = $null
    if ($quarantine.UseStorage) {
      $storagePath = Join-Path -Path $paths.StorageModsDir -ChildPath $mod.Name
      if (Test-Path -LiteralPath $storagePath) {
        $storageDest = Move-ToQuarantine -SourcePath $storagePath -DestDir $quarantine.StorageQuarantineDir -IsDryRun $false -Retries $quarantine.MoveRetryCount -DelayMs $quarantine.MoveRetryDelayMs
      }
    }

    [void](Add-MovedItemRecord -JarName $mod.Name `
        -GameSource $mod.FullName `
        -GameQuarantine $gameDest `
        -StorageSource $(if ($quarantine.UseStorage) { Join-Path -Path $paths.StorageModsDir -ChildPath $mod.Name } else { $null }) `
        -StorageQuarantine $storageDest `
        -Context $ctx)

    $ignoreHandles = @()
    if ($state.LastOutcomeHandleId -ne 0) {
      $ignoreHandles = @($state.LastOutcomeHandleId)
    }

    $attemptStart = Get-Date
    Set-IsolationStrategyPhase -Context $ctx -Phase "attempt_invoke_launch"
    $outcome = Invoke-ConfiguredLaunchAttempt -IgnoreHandleIds $ignoreHandles -Context $ctx

    Write-Host ("Outcome: {0}" -f $outcome.Type) -ForegroundColor $(if ($outcome.Type -eq "Timeout") { "Green" } else { "Yellow" })
    if ($outcome.Type -ne "Timeout" -and $null -ne $outcome.Window) {
      Set-IsolationStrategyPhase -Context $ctx -Phase "attempt_close_outcome_window"
      $state.LastOutcomeHandleId = Close-OutcomeWindowWithExtraDialog -Outcome $outcome `
        -DelaySeconds $timeouts.CrashCloseDelaySeconds `
        -OffsetX $ui.CrashCloseClickOffsetX `
        -OffsetY $ui.CrashCloseClickOffsetY `
        -CloseExtraFabricDialogs $true `
        -Context $ctx
    }
    if ($outcome.Type -ne "Timeout") {
      Set-IsolationStrategyPhase -Context $ctx -Phase "attempt_wait_game_exit"
      [void](Wait-ConfiguredGameExit -StartedAfter $attemptStart -Context $ctx)
    }

    Wait-ConfiguredLauncherInteractive -Context $ctx

    if ($outcome.Type -eq "Timeout") {
      $launchConfigKey = ""
      if ($outcome | Get-Member -Name "LaunchConfigKey" -MemberType NoteProperty, Property) {
        $launchConfigKey = [string]$outcome.LaunchConfigKey
      }
      if (-not [string]::IsNullOrWhiteSpace($launchConfigKey)) {
        Register-SessionLaunchConfigSuccess -ConfigKey $launchConfigKey -Context $ctx
      }
      return [pscustomobject]@{
        Found = $true
        CulpritJarNames = @($mod.Name)
        StopReason = "success"
      }
    }

    Start-Sleep -Seconds $strategy.LogPostRunDelaySeconds
    Set-IsolationStrategyPhase -Context $ctx -Phase "attempt_read_logs"
    $snapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $attemptStart -Context $ctx

    if ($state.McVersionForLegacy -eq "unknown") {
      $state.McVersionForLegacy = Get-MinecraftVersionFromLog -Lines $snapshot.Lines
    }

    # * Fabric signals (from window or from logs). This makes behavior visible in console output.
    $fabricIdsFromLogs = Get-FabricRequiringModId -Lines $snapshot.Lines
    $fabricMissingIdsFromLogs = Get-FabricMissingDependencyId -Lines $snapshot.Lines
    $fabricWindowNow = Select-WindowByTitlePattern -Patterns $ui.FabricWindowTitlePatterns
    if (($null -ne $fabricWindowNow) -or ($fabricIdsFromLogs -and $fabricIdsFromLogs.Count -gt 0) -or ($fabricMissingIdsFromLogs -and $fabricMissingIdsFromLogs.Count -gt 0)) {
      $reqText = if ($fabricIdsFromLogs -and $fabricIdsFromLogs.Count -gt 0) { $fabricIdsFromLogs -join ", " } else { "" }
      $missText = if ($fabricMissingIdsFromLogs -and $fabricMissingIdsFromLogs.Count -gt 0) { $fabricMissingIdsFromLogs -join ", " } else { "" }
      if (-not [string]::IsNullOrWhiteSpace($reqText) -or -not [string]::IsNullOrWhiteSpace($missText)) {
        Write-Host ("Fabric detected. Requiring mods: {0}; Missing deps: {1}" -f $reqText, $missText) -ForegroundColor Yellow
      } else {
        Write-Host "Fabric window detected." -ForegroundColor Yellow
      }
    }

    if ($outcome.Type -eq "FabricDialog") {
      # * Fabric dependency dialog:
      # * - Prefer isolating the requiring mod(s) (not the missing dependency).
      # * - If the removed jar is the missing dependency, restore it to avoid falsely blaming it.
      $newModIds = $fabricIdsFromLogs
      $missingDepIds = $fabricMissingIdsFromLogs
      $newModIdsArr = @($newModIds)
      $missingDepIdsArr = @($missingDepIds)

      $removedItem = $null
      for ($i = $quarantine.MovedItems.Count - 1; $i -ge 0; $i--) {
        if ($quarantine.MovedItems[$i].JarName -eq $mod.Name) { $removedItem = $quarantine.MovedItems[$i]; break }
      }
      $removedJarProvides = @()
      if ($null -ne $removedItem -and $null -ne $removedItem.GameQuarantine -and (Test-Path -LiteralPath $removedItem.GameQuarantine)) {
        $removedJarProvides = Get-FabricModIdsFromJar -JarPath $removedItem.GameQuarantine
      }
      $removedJarProvidesArr = @($removedJarProvides)

      $isLikelyRemovedDep = $false
      if ($missingDepIdsArr.Count -gt 0) {
        if ($removedJarProvidesArr.Count -gt 0) {
          $isLikelyRemovedDep = Test-AnyIdOverlap -IdsA $removedJarProvidesArr -IdsB $missingDepIdsArr
        }
        if (-not $isLikelyRemovedDep) {
          $isLikelyRemovedDep = Test-JarNameMatchesAnyId -JarName $mod.Name -Ids $missingDepIdsArr -AllowTokenMatch:$false
        }
      }

      if ($isLikelyRemovedDep) {
        Write-Host ("Fabric missing dependency '{0}' appears caused by removing '{1}'. Restoring dependency and isolating requiring mod(s)." -f ($missingDepIdsArr -join ", "), $mod.Name) -ForegroundColor Cyan

        if ($null -ne $removedItem -and $null -ne $removedItem.GameQuarantine -and (Test-Path -LiteralPath $removedItem.GameQuarantine)) {
          [void](Restore-FromQuarantine -SourcePath $removedItem.GameQuarantine -DestDir $paths.GameModsDir -IsDryRun $false -AllowOverwrite $true)
          $removedItem.GameQuarantine = $null
        }
        if ($quarantine.UseStorage -and $null -ne $removedItem -and $null -ne $removedItem.StorageQuarantine -and (Test-Path -LiteralPath $removedItem.StorageQuarantine)) {
          [void](Restore-FromQuarantine -SourcePath $removedItem.StorageQuarantine -DestDir $paths.StorageModsDir -IsDryRun $false -AllowOverwrite $true)
          $removedItem.StorageQuarantine = $null
        }
      }

      if ($newModIdsArr.Count -gt 0) {
        Write-Host ("Fabric dialog detected. Quick-isolating requiring mods: {0}" -f ($newModIdsArr -join ", ")) -ForegroundColor Cyan
        $searchDirs = @($paths.GameModsDir)
        if ($quarantine.GameQuarantineDir) { $searchDirs += $quarantine.GameQuarantineDir }
        if ($quarantine.StorageQuarantineDir) { $searchDirs += $quarantine.StorageQuarantineDir }
        $culpritJars = Find-ModJarByIdBestEffort -Dirs $searchDirs -ModIds $newModIdsArr -AllowTokenFallback:$false
        $culpritJars = Select-QuickIsolateJarsByTier -Jars $culpritJars -Context "fabric dialog" -MaxResults 1
        if ($culpritJars -and $culpritJars.Count -gt 0) {
          foreach ($cj in $culpritJars) {
            if ($quarantine.MovedJarNameSet.ContainsKey($cj.Name)) { continue }
            Write-Host ("Quick-isolating: {0}" -f $cj.Name) -ForegroundColor Cyan
            Set-IsolationStrategyPhase -Context $ctx -Phase "quick_isolate_move"
            $qDest = Move-ToQuarantine -SourcePath $cj.FullName -DestDir $quarantine.GameQuarantineDir -IsDryRun $false -Retries $quarantine.MoveRetryCount -DelayMs $quarantine.MoveRetryDelayMs
            if ($null -ne $qDest) {
              [void](Add-MovedItemRecord -JarName $cj.Name -GameSource $cj.FullName -GameQuarantine $qDest -StorageSource $null -StorageQuarantine $null -Context $ctx)
              $state.PinnedJarNameSet[$cj.Name.ToLowerInvariant()] = $cj.Name
            }
          }
        } else {
          Write-Host ("Warning: could not resolve or filtered requiring mod jar(s) for ids: {0}. Continuing isolation." -f ($newModIdsArr -join ", ")) -ForegroundColor Yellow
        }
        Write-Host "Continuing Isolation after Fabric quick-isolate..." -ForegroundColor Cyan
        continue
      }

      if ($isLikelyRemovedDep) {
        # * We restored the dependency; proceed with next candidate.
        Write-Host "Continuing Isolation after dependency restore..." -ForegroundColor Cyan
        continue
      }
    }

    $signature = Get-ErrorSignature -Lines $snapshot.Lines `
      -MaxLines $strategy.ErrorSignatureLineLimit `
      -IncludeWarnMixins ([bool]$strategy.IncludeWarnMixinsAsIncompatible)
    $evidenceKey = Get-ErrorEvidenceKey -Lines $snapshot.Lines -MaxLines $strategy.ErrorSignatureLineLimit

    Write-Verbose ("Signature: {0}" -f $signature)
    if (Test-SignatureChanged -Baseline $state.ActiveBaselineSignature -Current $signature `
        -BaselineEvidenceKey $state.ActiveBaselineEvidenceKey -CurrentEvidenceKey $evidenceKey `
        -IgnoreModsWhenEvidencePresent ([bool]$strategy.IgnoreModListForSignatureChange)) {
      # * Confirm signature change to avoid log-flush noise.
      Start-Sleep -Milliseconds 750
      $confirmSnapshot = Get-ConfiguredLogSnapshot -SinceTimestamp $attemptStart -Context $ctx
      $confirmSignature = Get-ErrorSignature -Lines $confirmSnapshot.Lines `
        -MaxLines $strategy.ErrorSignatureLineLimit `
        -IncludeWarnMixins ([bool]$strategy.IncludeWarnMixinsAsIncompatible)
      $confirmEvidenceKey = Get-ErrorEvidenceKey -Lines $confirmSnapshot.Lines -MaxLines $strategy.ErrorSignatureLineLimit
      if (-not (Test-SignatureChanged -Baseline $state.ActiveBaselineSignature -Current $confirmSignature `
            -BaselineEvidenceKey $state.ActiveBaselineEvidenceKey -CurrentEvidenceKey $confirmEvidenceKey `
            -IgnoreModsWhenEvidencePresent ([bool]$strategy.IgnoreModListForSignatureChange))) {
        Write-Verbose "Transient signature change detected; continuing."
        continue
      }

      # * Try to identify culprit mods from Fabric dependency errors.
      $newModIds = Get-FabricRequiringModId -Lines $snapshot.Lines
      $missingDepIds = Get-FabricMissingDependencyId -Lines $snapshot.Lines
      $newModIdsArr = @($newModIds)
      $missingDepIdsArr = @($missingDepIds)

      # * Special-case: if the "error change" is a missing dependency introduced by removing a library,
      # * then the removed jar is NOT the culprit. Restore it and instead isolate the requiring mod(s).
      $removedJarProvides = @()
      $removedItem = $null
      for ($i = $quarantine.MovedItems.Count - 1; $i -ge 0; $i--) {
        if ($quarantine.MovedItems[$i].JarName -eq $mod.Name) { $removedItem = $quarantine.MovedItems[$i]; break }
      }
      if ($null -ne $removedItem -and $null -ne $removedItem.GameQuarantine -and (Test-Path -LiteralPath $removedItem.GameQuarantine)) {
        $removedJarProvides = Get-FabricModIdsFromJar -JarPath $removedItem.GameQuarantine
      }
      $removedJarProvidesArr = @($removedJarProvides)

      $isLikelyRemovedDep = $false
      if ($newModIdsArr.Count -gt 0 -and $missingDepIdsArr.Count -gt 0) {
        if ($removedJarProvidesArr.Count -gt 0) {
          $isLikelyRemovedDep = Test-AnyIdOverlap -IdsA $removedJarProvidesArr -IdsB $missingDepIdsArr
        }
        if (-not $isLikelyRemovedDep) {
          $isLikelyRemovedDep = Test-JarNameMatchesAnyId -JarName $mod.Name -Ids $missingDepIdsArr -AllowTokenMatch:$false
        }
      }

      if ($isLikelyRemovedDep) {
        Write-Host ("Detected missing dependency caused by removed library '{0}'. Restoring it and isolating requiring mod(s)." -f $mod.Name) -ForegroundColor Cyan

        # * Restore removed dependency jar back to active mods (and storage if applicable).
        if ($null -ne $removedItem -and $null -ne $removedItem.GameQuarantine -and (Test-Path -LiteralPath $removedItem.GameQuarantine)) {
          [void](Restore-FromQuarantine -SourcePath $removedItem.GameQuarantine -DestDir $paths.GameModsDir -IsDryRun $false -AllowOverwrite $true)
          $removedItem.GameQuarantine = $null
        }
        if ($quarantine.UseStorage -and $null -ne $removedItem -and $null -ne $removedItem.StorageQuarantine -and (Test-Path -LiteralPath $removedItem.StorageQuarantine)) {
          [void](Restore-FromQuarantine -SourcePath $removedItem.StorageQuarantine -DestDir $paths.StorageModsDir -IsDryRun $false -AllowOverwrite $true)
          $removedItem.StorageQuarantine = $null
        }

        # * Isolate the requiring mods instead.
        $searchDirs = @($paths.GameModsDir)
        if ($quarantine.GameQuarantineDir) { $searchDirs += $quarantine.GameQuarantineDir }
        if ($quarantine.StorageQuarantineDir) { $searchDirs += $quarantine.StorageQuarantineDir }
        $requiringJars = Find-ModJarByIdBestEffort -Dirs $searchDirs -ModIds $newModIdsArr -AllowTokenFallback:$false
        $requiringJars = Select-QuickIsolateJarsByTier -Jars $requiringJars -Context "dependency signature" -MaxResults 1
        if ($requiringJars -and $requiringJars.Count -gt 0) {
          $culpritJarNames = @()
          foreach ($rj in $requiringJars) {
            Write-Host ("Isolating requiring mod: {0}" -f $rj.Name) -ForegroundColor Cyan
            $rDest = Move-ToQuarantine -SourcePath $rj.FullName -DestDir $quarantine.GameQuarantineDir -IsDryRun $false -Retries $quarantine.MoveRetryCount -DelayMs $quarantine.MoveRetryDelayMs
            $rStorageDest = $null
            if ($quarantine.UseStorage) {
              $rStoragePath = Join-Path -Path $paths.StorageModsDir -ChildPath $rj.Name
              if (Test-Path -LiteralPath $rStoragePath) {
                $rStorageDest = Move-ToQuarantine -SourcePath $rStoragePath -DestDir $quarantine.StorageQuarantineDir -IsDryRun $false -Retries $quarantine.MoveRetryCount -DelayMs $quarantine.MoveRetryDelayMs
              }
            }
            [void](Add-MovedItemRecord -JarName $rj.Name `
                -GameSource $rj.FullName `
                -GameQuarantine $rDest `
                -StorageSource $(if ($quarantine.UseStorage) { Join-Path -Path $paths.StorageModsDir -ChildPath $rj.Name } else { $null }) `
                -StorageQuarantine $rStorageDest `
                -Context $ctx)
            $state.PinnedJarNameSet[$rj.Name.ToLowerInvariant()] = $rj.Name
            $culpritJarNames += @($rj.Name)
          }
          return [pscustomobject]@{
            Found = $true
            CulpritJarNames = @($culpritJarNames)
            StopReason = "fabric_missing_dependency"
          }
        }

        # ! If we cannot map requiring mod IDs to jar files, do NOT blame the removed library.
        # ! The safest behavior is to continue isolation with the library restored.
        Write-Host ("Warning: could not resolve requiring mod jar(s) for ids: {0}. Continuing isolation." -f ($newModIdsArr -join ", ")) -ForegroundColor Yellow
        continue
      }

      $movedExtra = $false
      if ($newModIds -and $newModIds.Count -gt 0) {
        Write-Host ("Fabric dependency error detected. Mods requiring missing deps: {0}" -f ($newModIds -join ", ")) -ForegroundColor Yellow
        $searchDirs = @($paths.GameModsDir)
        if ($quarantine.GameQuarantineDir) { $searchDirs += $quarantine.GameQuarantineDir }
        if ($quarantine.StorageQuarantineDir) { $searchDirs += $quarantine.StorageQuarantineDir }
        $culpritJars = Find-ModJarByIdBestEffort -Dirs $searchDirs -ModIds $newModIds -AllowTokenFallback:$false
        $culpritJars = Select-QuickIsolateJarsByTier -Jars $culpritJars -Context "dependency signature" -MaxResults 1
        if ($culpritJars -and $culpritJars.Count -gt 0) {
          foreach ($cj in $culpritJars) {
            # * Skip if already moved.
            if ($quarantine.MovedJarNameSet.ContainsKey($cj.Name)) { continue }

            Write-Host ("Quick-isolating: {0}" -f $cj.Name) -ForegroundColor Cyan
            Set-IsolationStrategyPhase -Context $ctx -Phase "quick_isolate_move"
            $qDest = Move-ToQuarantine -SourcePath $cj.FullName -DestDir $quarantine.GameQuarantineDir -IsDryRun $false -Retries $quarantine.MoveRetryCount -DelayMs $quarantine.MoveRetryDelayMs
            if ($null -ne $qDest) {
              [void](Add-MovedItemRecord -JarName $cj.Name -GameSource $cj.FullName -GameQuarantine $qDest -StorageSource $null -StorageQuarantine $null -Context $ctx)
              $state.PinnedJarNameSet[$cj.Name.ToLowerInvariant()] = $cj.Name
              $movedExtra = $true
            }
          }
        }
      }
      if ($movedExtra) {
        # * Continue isolation with newly identified mods removed.
        Write-Host "Continuing Isolation after quick-isolate..." -ForegroundColor Cyan
        continue
      }
      return [pscustomobject]@{
        Found = $true
        CulpritJarNames = @($mod.Name)
        StopReason = "error_changed"
      }
    }
  }

  return [pscustomobject]@{
    Found = $false
    CulpritJarNames = @()
    StopReason = ""
  }
}

# * Runs tiered hybrid isolation (exponential/binary within tiers, then linear).
function Invoke-HybridIsolation {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Mods,
    [Parameter(Mandatory = $true)]
    [string]$BaselineSignature,
    [Parameter(Mandatory = $true)]
    [string]$BaselineEvidenceKey,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $ctx = Resolve-IsolationStrategyContext -Context $Context
  $state = $ctx.State
  $strategy = $ctx.Strategy

  $result = [pscustomobject]@{
    Found = $false
    CulpritJarNames = @()
    StopReason = ""
  }

  if (-not $Mods -or $Mods.Count -eq 0) { return $result }

  $maxTier = 4
  for ($tier = 1; $tier -le $maxTier; $tier++) {
    Set-IsolationStrategyCurrentDependencyTier -Context $ctx -Tier $tier
    $tierMods = @($Mods | Where-Object {
        if ($_.PSObject.Properties.Name -contains "DependentModTier") {
          $_.DependentModTier -eq $tier
        } else {
          $fallbackTier = if ([bool]$strategy.DependencyAwareTreatUnknownAsCore) { 4 } else { 1 }
          $fallbackTier -eq $tier
        }
      })
    if (-not $tierMods -or $tierMods.Count -eq 0) { continue }

    Write-Host ("Tier {0}: {1} mod(s)" -f $tier, $tierMods.Count) -ForegroundColor Gray

    $pinnedJarNames = @()
    if ($state.PinnedJarNameSet.Count -gt 0) {
      $pinnedJarNames = @($state.PinnedJarNameSet.Values)
    }

    Update-QuarantineState -DesiredJarNames @() -PinnedJarNames $pinnedJarNames -Context $ctx

    if (-not $state.BaselineSucceeded) {
      $pinnedKey = Get-PinnedJarNameKey -Context $ctx
      if (-not [string]::Equals($pinnedKey, $state.LastBaselinePinnedKey, [System.StringComparison]::OrdinalIgnoreCase)) {
        $refresh = Invoke-LinearBaselineRefresh -PhasePrefix ("tier{0}_baseline" -f $tier) -Context $ctx
        if (-not $refresh.ShouldContinue) {
          if ($state.BlockedByDependency) {
            $result.StopReason = "dependency_dialog_tier_baseline"
          }
          Set-IsolationStrategyCurrentDependencyTier -Context $ctx -Tier 0
          return $result
        }
      }
    }

    $tierCandidates = @($tierMods | Where-Object { -not $state.PinnedJarNameSet.ContainsKey($_.Name.ToLowerInvariant()) })
    if (-not $tierCandidates -or $tierCandidates.Count -eq 0) { continue }

    $tierRemaining = $tierCandidates
    if ($strategy.DependencyAwareExponentialMaxTier -gt 0 -and $tier -le $strategy.DependencyAwareExponentialMaxTier) {
      Write-Host ("Tier {0}: exponential Isolation enabled. Candidates: {1}" -f $tier, $tierCandidates.Count) -ForegroundColor Gray
      $tierBaselineSignature = if ([string]::IsNullOrWhiteSpace($state.ActiveBaselineSignature)) { $BaselineSignature } else { $state.ActiveBaselineSignature }
      $tierBaselineEvidenceKey = if ([string]::IsNullOrWhiteSpace($state.ActiveBaselineEvidenceKey)) { $BaselineEvidenceKey } else { $state.ActiveBaselineEvidenceKey }
      $exponentialResult = Invoke-ExponentialIsolation -Mods $tierCandidates `
        -BaselineSignature $tierBaselineSignature `
        -BaselineEvidenceKey $tierBaselineEvidenceKey `
        -PinnedJarNames $pinnedJarNames `
        -Context $ctx
      $tierRemaining = @($exponentialResult.Remaining)
      Write-Host ("Tier {0}: exponential Isolation completed. Linear with {1} mod(s) ({2})." -f $tier, $tierRemaining.Count, $exponentialResult.Reason) -ForegroundColor Gray
    }

    if (-not $tierRemaining -or $tierRemaining.Count -eq 0) { continue }

    if (-not $state.BaselineSucceeded) {
      $pinnedKey = Get-PinnedJarNameKey -Context $ctx
      if (-not [string]::Equals($pinnedKey, $state.LastBaselinePinnedKey, [System.StringComparison]::OrdinalIgnoreCase)) {
        $refresh = Invoke-LinearBaselineRefresh -PhasePrefix ("tier{0}_linear" -f $tier) -Context $ctx
        if (-not $refresh.ShouldContinue) {
          if ($state.BlockedByDependency) {
            $result.StopReason = "dependency_dialog_tier_linear"
          }
          Set-IsolationStrategyCurrentDependencyTier -Context $ctx -Tier 0
          return $result
        }
      }
    }

    $linearResult = Invoke-LinearIsolation -Mods $tierRemaining -Context $ctx
    if ($linearResult.Found) {
      Set-IsolationStrategyCurrentDependencyTier -Context $ctx -Tier 0
      return $linearResult
    }

    $pinnedJarNames = @()
    if ($state.PinnedJarNameSet.Count -gt 0) {
      $pinnedJarNames = @($state.PinnedJarNameSet.Values)
    }
    Update-QuarantineState -DesiredJarNames @() -PinnedJarNames $pinnedJarNames -Context $ctx
  }

  Set-IsolationStrategyCurrentDependencyTier -Context $ctx -Tier 0
  return $result
}
