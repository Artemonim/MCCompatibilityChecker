<#
.SYNOPSIS
Post-Изоляция Recovery: detects culprits that share the same Mixin error and
attempts to restore them by removing the actual root-cause mod instead.

.DESCRIPTION
After layering/isolation identifies culprits, this script groups them by their
Mixin error line. If 3+ culprits share the same error, they are likely "phantom"
culprits triggered by a broken Mixin relationship between two other mods.
The script quarantines the root-cause mod (named in the Mixin error), restores
the phantom culprits, and verifies stability with a single game launch.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  # * JSON string of culprit records: array of { JarName, CrashEvidenceKey, StorageLegacyPath, GameLegacyPath }.
  [Parameter(Mandatory = $true)]
  [string]$CulpritDataJson,

  [Parameter(Mandatory = $false)]
  [string]$GameModsDir = "",

  [Parameter(Mandatory = $false)]
  [string]$GameLegacyFolderName = "",

  [Parameter(Mandatory = $false)]
  [string]$StorageModsDir = "",

  [Parameter(Mandatory = $false)]
  [string]$StorageLegacyFolderName = "",

  [Parameter(Mandatory = $false)]
  [switch]$KeepCulpritInGameLegacy,

  [Parameter(Mandatory = $false)]
  [string]$Minecraft = "unknown",

  [Parameter(Mandatory = $false)]
  [int]$MinGroupSize = 3,

  [Parameter(Mandatory = $false)]
  [string[]]$GameProcessNames = @("javaw", "java", "Minecraft"),

  [Parameter(Mandatory = $false)]
  [int]$WaitForGameExitSeconds = 30,

  [Parameter(Mandatory = $false)]
  [int]$GameExitPollSeconds = 2,

  [Parameter(Mandatory = $false)]
  [int]$SuccessConfirmSeconds = 20,

  [Parameter(Mandatory = $false)]
  [string]$LauncherExePath = "",

  [Parameter(Mandatory = $false)]
  [string[]]$LauncherArguments = @(),

  [Parameter(Mandatory = $false)]
  [Alias("Auto")]
  [switch]$UseAutoLaunch,

  [Parameter(Mandatory = $false)]
  [string]$LauncherWindowTitlePattern = "Legacy Launcher",

  [Parameter(Mandatory = $false)]
  [string[]]$PlayButtonNames = @("Launch", "Play", "Start"),

  [Parameter(Mandatory = $false)]
  [int]$PlayClickOffsetX = -1,

  [Parameter(Mandatory = $false)]
  [int]$PlayClickOffsetY = -1,

  [Parameter(Mandatory = $false)]
  [int]$PlayClickDelayMs = 1000,

  [Parameter(Mandatory = $false)]
  [int]$LaunchStartTimeoutSeconds = 15,

  [Parameter(Mandatory = $false)]
  [int]$PlayClickMaxAttempts = 2,

  [Parameter(Mandatory = $false)]
  [bool]$RequireGameStartForTimeout = $true,

  [Parameter(Mandatory = $false)]
  [bool]$UseEnterFallback = $true,

  [Parameter(Mandatory = $false)]
  [bool]$EnableBroadUiSearch = $false,

  [Parameter(Mandatory = $false)]
  [string[]]$CrashWindowTitlePatterns = @("Something broke"),

  [Parameter(Mandatory = $false)]
  [string[]]$FabricWindowTitlePatterns = @("Fabric Loader", "owo-sentinel"),

  [Parameter(Mandatory = $false)]
  [int]$CrashCloseClickOffsetX = -1,

  [Parameter(Mandatory = $false)]
  [int]$CrashCloseClickOffsetY = -1,

  [Parameter(Mandatory = $false)]
  [int]$CrashCloseDelaySeconds = 5,

  [Parameter(Mandatory = $false)]
  [int]$LauncherWindowTimeoutSeconds = 60,

  [Parameter(Mandatory = $false)]
  [int]$OutcomeTimeoutSeconds = 20,

  [Parameter(Mandatory = $false)]
  [int]$PollIntervalSeconds = 2,

  [Parameter(Mandatory = $false)]
  [ValidateSet("Tool", "File", "Internal")]
  [string]$DependencyMapSource = "File",

  [Parameter(Mandatory = $false)]
  [string]$DependencyMapJsonPath = "",

  [Parameter(Mandatory = $false)]
  [string]$DependencyMapToolPath = "",

  [Parameter(Mandatory = $false)]
  [string]$DependencyMapOutDir = "",

  [Parameter(Mandatory = $false)]
  [switch]$EmitResultObject,

  [Parameter(Mandatory = $false)]
  [switch]$DryRun
)

$sharedBootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Bootstrap.ps1"
if (-not (Test-Path -LiteralPath $sharedBootstrapPath)) {
  throw ("Shared bootstrap helpers not found: {0}" -f $sharedBootstrapPath)
}
. $sharedBootstrapPath
. Initialize-McccRuntimeBootstrap `
  -StartDir $PSScriptRoot `
  -LoadConfig `
  -InitializeLocalization `
  -EnableConsoleLocalization `
  -ConfigNotFoundMessage "Shared config helpers not found: {0}" `
  -LocalizationNotFoundMessage "Shared localization helpers not found: {0}" | Out-Null
if (-not $PSBoundParameters.ContainsKey("CrashWindowTitlePatterns")) {
  $CrashWindowTitlePatterns = Get-McccLocaleCrashWindowTitlePatternSet -StartDir $PSScriptRoot -FallbackPatterns $CrashWindowTitlePatterns
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# * Launch wait scaling config.
$launchWaitBaseSeconds = 20
$launchWaitPerModSeconds = 0.1

function Wait-RecoveryOutcomeDialog {
  param(
    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds,
    [Parameter(Mandatory = $false)]
    [int]$PollMilliseconds = 250
  )

  if ($TimeoutSeconds -lt 1) { return $null }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $crashWindow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
    if ($null -ne $crashWindow) {
      return [pscustomobject]@{
        Type = "CrashDialog"
        Window = $crashWindow
      }
    }

    $fabricWindow = Select-WindowByTitlePattern -Patterns $FabricWindowTitlePatterns
    if ($null -ne $fabricWindow) {
      return [pscustomobject]@{
        Type = "FabricDialog"
        Window = $fabricWindow
      }
    }

    Start-Sleep -Milliseconds $PollMilliseconds
  }

  return $null
}

$useDynamicOutcomeTimeout = -not $PSBoundParameters.ContainsKey("OutcomeTimeoutSeconds")
$useDynamicSuccessConfirm = -not $PSBoundParameters.ContainsKey("SuccessConfirmSeconds")

# ────────────────────────────────────────────────────────────────────────────
# * Load shared modules.
# ────────────────────────────────────────────────────────────────────────────

$sharedUiPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LauncherUi.ps1"
. $sharedUiPath
$sharedLauncherPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Launcher.ps1"
. $sharedLauncherPath
$sharedLogParsingPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-LogParsing.ps1"
. $sharedLogParsingPath
$sharedJarDepPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-JarDependencies.ps1"
. $sharedJarDepPath
$sharedLogPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LogTools.ps1"
if (-not (Test-Path -LiteralPath $sharedLogPath)) { throw ("Shared log helpers not found: {0}" -f $sharedLogPath) }
. $sharedLogPath
$sharedLegacyPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Legacy.ps1"
if (-not (Test-Path -LiteralPath $sharedLegacyPath)) { throw ("Shared legacy helpers not found: {0}" -f $sharedLegacyPath) }
. $sharedLegacyPath

$sharedFileOpsPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-FileOps.ps1"
if (-not (Test-Path -LiteralPath $sharedFileOpsPath)) { throw ("Shared file operation helpers not found: {0}" -f $sharedFileOpsPath) }
. $sharedFileOpsPath

$sharedStageResultPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-StageResult.ps1"
if (-not (Test-Path -LiteralPath $sharedStageResultPath)) { throw ("Shared stage result helpers not found: {0}" -f $sharedStageResultPath) }
. $sharedStageResultPath
$runtimeConfig = Initialize-McccRuntimeConfig `
  -StartDir $PSScriptRoot `
  -BoundParameters $PSBoundParameters `
  -GameModsDir $GameModsDir `
  -StorageModsDir $StorageModsDir `
  -LogPath $LogPath `
  -LauncherExePath $LauncherExePath `
  -AlwaysDefaultGameModsDir $true `
  -DefaultStorageToGame $false `
  -TreatEmptyAsUnboundKeys @("GameModsDir", "StorageModsDir", "LogPath", "LauncherExePath")
$GameModsDir = $runtimeConfig.Paths.GameModsDir
$StorageModsDir = $runtimeConfig.Paths.StorageModsDir
$LogPath = $runtimeConfig.Paths.LogPath
$LauncherExePath = $runtimeConfig.Paths.LauncherExePath
$useStorage = $runtimeConfig.Paths.UseStorage

$resolvedLegacyFolders = Resolve-McccLegacyFolderNames `
  -GameLegacyFolderName $GameLegacyFolderName `
  -StorageLegacyFolderName $StorageLegacyFolderName
$GameLegacyFolderName = [string]$resolvedLegacyFolders.GameLegacyFolderName
$StorageLegacyFolderName = [string]$resolvedLegacyFolders.StorageLegacyFolderName

# ────────────────────────────────────────────────────────────────────────────
# * Parse culprit data.
# ────────────────────────────────────────────────────────────────────────────

$culprits = @()
try {
  $culprits = @($CulpritDataJson | ConvertFrom-Json -ErrorAction Stop)
} catch {
  Write-Host ("Recovery: failed to parse culprit data: {0}" -f $_.Exception.Message) -ForegroundColor Red
  exit 1
}

if ($culprits.Count -eq 0) {
  Write-Host "Recovery: no culprits provided." -ForegroundColor Gray
  if ($EmitResultObject) {
    $stageResultParams = @{
      Stage = "Recovery"
      Type = "RecoveryResult"
      GameModsDir = $GameModsDir
      StorageModsDir = if ($useStorage) { $StorageModsDir } else { "" }
      Minecraft = $Minecraft
      ExitCode = 0
      CulpritJarNames = @()
      CulpritMoves = @()
      ExtraFields = @{
        RestoredJarNames   = @()
        NewCulpritJarNames = @()
        Attempted          = $false
      }
    }
    Write-Output (New-StageResult @stageResultParams)
  }
  exit 0
}

# ────────────────────────────────────────────────────────────────────────────
# * Group culprits by Mixin error line.
# ────────────────────────────────────────────────────────────────────────────

$mixinPattern = '@Mixin target\s+(?<targetClass>\S+)\s+was not found\s+(?<mixinJson>\S+?):(?<mixinClass>\S+)\s+from mod\s+(?<sourceModId>[a-z0-9_\-\.]+)'
$groups = @{}

foreach ($c in $culprits) {
  $ek = [string]$c.CrashEvidenceKey
  if ([string]::IsNullOrWhiteSpace($ek)) { continue }
  $m = [regex]::Match($ek, $mixinPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $m.Success) { continue }
  $key = $m.Value
  if (-not $groups.ContainsKey($key)) {
    $groups[$key] = @{
      SourceModId = $m.Groups["sourceModId"].Value.ToLowerInvariant()
      TargetClass = $m.Groups["targetClass"].Value
      Members     = New-Object System.Collections.Generic.List[pscustomobject]
    }
  }
  $groups[$key].Members.Add($c)
}

$qualifiedGroups = @($groups.Values | Where-Object { $_.Members.Count -ge $MinGroupSize })

if ($qualifiedGroups.Count -eq 0) {
  Write-Host ("Recovery: no Mixin error groups with {0}+ culprits found. Nothing to recover." -f $MinGroupSize) -ForegroundColor Gray
  if ($EmitResultObject) {
    $stageResultParams = @{
      Stage = "Recovery"
      Type = "RecoveryResult"
      GameModsDir = $GameModsDir
      StorageModsDir = if ($useStorage) { $StorageModsDir } else { "" }
      Minecraft = $Minecraft
      ExitCode = 0
      CulpritJarNames = @()
      CulpritMoves = @()
      ExtraFields = @{
        RestoredJarNames   = @()
        NewCulpritJarNames = @()
        Attempted          = $false
      }
    }
    Write-Output (New-StageResult @stageResultParams)
  }
  exit 0
}

# ────────────────────────────────────────────────────────────────────────────
# * Load dependency map for mod ID → JAR resolution.
# ────────────────────────────────────────────────────────────────────────────

$dependencyMap = Get-DependencyMapFromSource -ScanPath $GameModsDir
$modIdToJar = @{}
$knownModIds = @{}
if ($null -ne $dependencyMap) {
  foreach ($mod in @($dependencyMap.Mods)) {
    if ($null -eq $mod) { continue }
    $id = [string]$mod.ModId
    $jar = [string]$mod.JarName
    if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($jar)) { continue }
    $modIdToJar[$id.ToLowerInvariant()] = $jar
    $knownModIds[$id.ToLowerInvariant()] = $true
  foreach ($providedId in @($mod.ProvidedModIds)) {
    $p = [string]$providedId
      if (-not [string]::IsNullOrWhiteSpace($p)) {
        $modIdToJar[$p.ToLowerInvariant()] = $jar
        $knownModIds[$p.ToLowerInvariant()] = $true
      }
    }
  }
}

# ────────────────────────────────────────────────────────────────────────────
# * Process each qualified group.
# ────────────────────────────────────────────────────────────────────────────

$allRestoredJarNames = New-Object System.Collections.Generic.List[string]
$allNewCulpritJarNames = New-Object System.Collections.Generic.List[string]
$attempted = $false
$script:lastOutcomeHandleId = 0

foreach ($group in $qualifiedGroups) {
  $sourceModId = $group.SourceModId
  $targetModId = Resolve-ModIdFromClassName -ClassName $group.TargetClass -KnownModIds $knownModIds

  Write-Host ""
  Write-Host ("Recovery: {0} culprits share Mixin error: mod '{1}' → class '{2}'" -f $group.Members.Count, $sourceModId, $group.TargetClass) -ForegroundColor Cyan

  # * Find root-cause JAR candidates (source first, then target).
  $rootCandidates = @()
  if ($modIdToJar.ContainsKey($sourceModId)) {
    $rootCandidates += [pscustomobject]@{ ModId = $sourceModId; JarName = $modIdToJar[$sourceModId] }
  }
  if ($null -ne $targetModId -and $targetModId -ne $sourceModId -and $modIdToJar.ContainsKey($targetModId)) {
    $rootCandidates += [pscustomobject]@{ ModId = $targetModId; JarName = $modIdToJar[$targetModId] }
  }

  if ($rootCandidates.Count -eq 0) {
    Write-Host "  Cannot resolve root-cause mod IDs to JARs. Skipping group." -ForegroundColor Yellow
    continue
  }

  foreach ($rootCand in $rootCandidates) {
    $rootJar = $rootCand.JarName
    $rootGamePath = Join-Path -Path $GameModsDir -ChildPath $rootJar

    if (-not (Test-Path -LiteralPath $rootGamePath)) {
      Write-Host ("  Root-cause candidate {0} not in game mods. Skipping." -f $rootJar) -ForegroundColor Gray
      continue
    }

    Write-Host ("  Testing hypothesis: root cause = {0} (mod: {1})" -f $rootJar, $rootCand.ModId) -ForegroundColor Cyan
    $attempted = $true

    if ($DryRun) {
      Write-Host "  DRYRUN: would quarantine root, restore culprits, and test." -ForegroundColor Gray
      continue
    }

    # * Step 1: Quarantine root-cause JAR.
    $tempRootDir = Get-McccLegacyTempRootPath -ModsDir $GameModsDir -GameLegacyFolderName $GameLegacyFolderName
    $tempDir = Join-Path -Path $tempRootDir -ChildPath ("recovery-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    if (-not (Test-Path -LiteralPath $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
    $rootTemp = Join-Path -Path $tempDir -ChildPath $rootJar
    $quarantineRootResult = Move-McccItem -LiteralPath $rootGamePath -DestinationPath $rootTemp -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
    if (-not $quarantineRootResult.Performed) {
      throw ("Failed to quarantine root-cause mod: {0}" -f $rootGamePath)
    }
    Write-Host ("  Quarantined root-cause: {0}" -f $rootJar) -ForegroundColor Gray

    $rootStorageTemp = $null
    $rootStoragePath = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $rootJar } else { $null }
    if ($useStorage -and $rootStoragePath -and (Test-Path -LiteralPath $rootStoragePath)) {
      $rootStorageTemp = Join-Path -Path $tempDir -ChildPath ("storage-{0}" -f $rootJar)
      $quarantineStorageResult = Move-McccItem -LiteralPath $rootStoragePath -DestinationPath $rootStorageTemp -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
      if (-not $quarantineStorageResult.Performed) {
        throw ("Failed to quarantine storage root-cause mod: {0}" -f $rootStoragePath)
      }
    }

    # * Step 2: Restore all phantom culprits back to game mods.
    $restoredPaths = @{}
    foreach ($member in $group.Members) {
      $mJar = [string]$member.JarName
      $gameTarget = Join-Path -Path $GameModsDir -ChildPath $mJar

      # * Restore from storage legacy (copy).
      $sLeg = [string]$member.StorageLegacyPath
      if (-not [string]::IsNullOrWhiteSpace($sLeg) -and (Test-Path -LiteralPath $sLeg)) {
        $copyToGameResult = Copy-McccItem -LiteralPath $sLeg -DestinationPath $gameTarget -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        if (-not $copyToGameResult.Performed) {
          throw ("Failed to restore mod from storage legacy: {0}" -f $mJar)
        }
        if ($useStorage) {
          $storageTarget = Join-Path -Path $StorageModsDir -ChildPath $mJar
          $copyToStorageResult = Copy-McccItem -LiteralPath $sLeg -DestinationPath $storageTarget -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
          if (-not $copyToStorageResult.Performed) {
            throw ("Failed to restore mod into storage root: {0}" -f $mJar)
          }
        }
        $restoredPaths[$mJar] = $sLeg
        Write-Host ("  Restored: {0}" -f $mJar) -ForegroundColor Gray
        continue
      }

      # * Restore from game legacy.
      $gLeg = [string]$member.GameLegacyPath
      if (-not [string]::IsNullOrWhiteSpace($gLeg) -and (Test-Path -LiteralPath $gLeg)) {
        $copyFromGameLegacyResult = Copy-McccItem -LiteralPath $gLeg -DestinationPath $gameTarget -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        if (-not $copyFromGameLegacyResult.Performed) {
          throw ("Failed to restore mod from game legacy: {0}" -f $mJar)
        }
        $restoredPaths[$mJar] = $gLeg
        Write-Host ("  Restored: {0}" -f $mJar) -ForegroundColor Gray
      }
    }

    # * Step 3: Launch game and check stability.
    $isSuccess = $false
    $launchStart = $null
    try {
      $strayCrash = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
      if ($null -ne $strayCrash) {
        Invoke-WindowClose -Handle $strayCrash.Handle
        Start-Sleep -Seconds 2
      }

      $effectiveConfirmSeconds = $SuccessConfirmSeconds
      if ($useDynamicOutcomeTimeout -or $useDynamicSuccessConfirm) {
        $activeModCount = Get-ActiveModCount -ModsDir $GameModsDir
        $scaledLaunchSeconds = Get-ScaledLaunchWaitTime -ActiveModCount $activeModCount `
          -PerModSeconds $launchWaitPerModSeconds `
          -BaseSeconds $launchWaitBaseSeconds
        if ($useDynamicOutcomeTimeout) { $OutcomeTimeoutSeconds = $scaledLaunchSeconds }
        if ($useDynamicSuccessConfirm) { $effectiveConfirmSeconds = $scaledLaunchSeconds }
      }

      $ignoreHandles = @()
      if ($script:lastOutcomeHandleId -ne 0) {
        $ignoreHandles = @($script:lastOutcomeHandleId)
      }

      $launchStart = Get-Date
      $outcome = Invoke-ConfiguredLaunchAttempt -IgnoreHandleIds $ignoreHandles

      # * Race guard: Fabric dialog can appear right after the launcher outcome.
      if ($outcome.Type -ne "FabricDialog") {
        $fabricNow = Select-WindowByTitlePattern -Patterns $FabricWindowTitlePatterns
        if ($null -ne $fabricNow) {
          Write-Host ("  Detected Fabric dialog after outcome: {0}" -f $fabricNow.Title) -ForegroundColor Yellow
          $outcome = [pscustomobject]@{
            Type = "FabricDialog"
            Window = $fabricNow
          }
        }
      }

      # * Race guard: crash dialog may appear shortly after ProcessExit/Timeout.
      if ($outcome.Type -ne "FabricDialog" -and $outcome.Type -ne "CrashDialog") {
        $crashNow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
        if ($null -ne $crashNow) {
          Write-Host ("  Detected crash dialog after outcome: {0}" -f $crashNow.Title) -ForegroundColor Yellow
          $outcome = [pscustomobject]@{
            Type = "CrashDialog"
            Window = $crashNow
          }
        }
      }

      if ($outcome.Type -eq "ProcessExit") {
        [void](Wait-ConfiguredGameExit -StartedAfter $launchStart -WarningContext "Recovery process exit")
        # * Some launchers show crash/fabric dialogs with delay after java exits.
        $lateAfterExit = Wait-RecoveryOutcomeDialog -TimeoutSeconds 5
        if ($null -ne $lateAfterExit) {
          Write-Host ("  Detected {0} after ProcessExit: {1}" -f $lateAfterExit.Type, $lateAfterExit.Window.Title) -ForegroundColor Yellow
          $outcome = $lateAfterExit
        }
      }

      $outcomeColor = if ($outcome.Type -match "CrashDialog|FabricDialog|NoLaunch") { "Yellow" } else { "Green" }
      Write-Host ("  Outcome: {0}" -f $outcome.Type) -ForegroundColor $outcomeColor

      if ($outcome.Type -eq "Timeout") {
        Start-Sleep -Seconds $effectiveConfirmSeconds
        $lateAfterTimeout = Wait-RecoveryOutcomeDialog -TimeoutSeconds 3
        if ($null -eq $lateAfterTimeout) {
          $isSuccess = $true
        } else {
          $outcome = $lateAfterTimeout
        }
        [void](Stop-ConfiguredGameProcess -StartedAfter $launchStart)
      }

      if (($outcome.Type -eq "CrashDialog" -or $outcome.Type -eq "FabricDialog") -and $null -ne $outcome.Window) {
        $script:lastOutcomeHandleId = Close-OutcomeWindowWithExtraDialog -Outcome $outcome `
          -DelaySeconds $CrashCloseDelaySeconds `
          -OffsetX $CrashCloseClickOffsetX `
          -OffsetY $CrashCloseClickOffsetY `
          -CloseExtraFabricDialogs $true
      }

      $postDialog = Wait-RecoveryOutcomeDialog -TimeoutSeconds 2
      if ($null -ne $postDialog -and $null -ne $postDialog.Window) {
        $script:lastOutcomeHandleId = Close-OutcomeWindowWithExtraDialog `
          -Outcome $postDialog `
          -DelaySeconds $CrashCloseDelaySeconds `
          -OffsetX $CrashCloseClickOffsetX `
          -OffsetY $CrashCloseClickOffsetY `
          -CloseExtraFabricDialogs $true
      }
    } catch {
      # ! Error during launch/verification — revert all changes and re-throw.
      Write-Host ("  Error during Recovery verification: {0}. Rolling back." -f $_.Exception.Message) -ForegroundColor Red
      foreach ($mJar in $restoredPaths.Keys) {
        $mGamePath = Join-Path -Path $GameModsDir -ChildPath $mJar
        if (Test-Path -LiteralPath $mGamePath) {
          try {
            $null = Remove-McccItem -LiteralPath $mGamePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
          } catch { }
        }
        if ($useStorage) {
          $mStoragePath = Join-Path -Path $StorageModsDir -ChildPath $mJar
          if (Test-Path -LiteralPath $mStoragePath) {
            try {
              $null = Remove-McccItem -LiteralPath $mStoragePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
            } catch { }
          }
        }
      }
      if (Test-Path -LiteralPath $rootTemp) {
        try {
          $null = Move-McccItem -LiteralPath $rootTemp -DestinationPath $rootGamePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        } catch { }
      }
      if ($null -ne $rootStorageTemp -and (Test-Path -LiteralPath $rootStorageTemp) -and $null -ne $rootStoragePath) {
        try {
          $null = Move-McccItem -LiteralPath $rootStorageTemp -DestinationPath $rootStoragePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        } catch { }
      }
      throw
    } finally {
      if ($null -ne $launchStart) {
        [void](Stop-ConfiguredGameProcess -StartedAfter $launchStart)
        [void](Wait-ConfiguredGameExit -StartedAfter $launchStart -WarningContext "Recovery cleanup")
      }
    }

    if ($isSuccess) {
      # * Recovery successful! Root-cause confirmed.
      Write-Host ("  Recovery SUCCESS: {0} is the root cause. {1} culprit(s) restored." -f $rootJar, $restoredPaths.Count) -ForegroundColor Green

      # * Move root-cause to legacy permanently.
      $storageSourcePath = Get-FirstExistingPath -Candidates @($rootStorageTemp, $rootTemp)
      $gameSourcePath = Get-FirstExistingPath -Candidates @($rootTemp)
      $null = Move-CulpritToLegacyAndAppendLog `
        -JarName $rootJar `
        -MinecraftVersion $Minecraft `
        -GameModsDir $GameModsDir `
        -StorageModsDir $StorageModsDir `
        -GameLegacyFolderName $GameLegacyFolderName `
        -StorageLegacyFolderName $StorageLegacyFolderName `
        -KeepCulpritInGameLegacy ([bool]$KeepCulpritInGameLegacy) `
        -StorageSourcePath $storageSourcePath `
        -GameSourcePath $gameSourcePath `
        -StorageTransferMode "Copy" `
        -GameTransferMode "Copy"

      # * Remove original legacy copies of restored culprits.
      foreach ($mJar in $restoredPaths.Keys) {
        $legPath = $restoredPaths[$mJar]
        if (Test-Path -LiteralPath $legPath) {
          try {
            $null = Remove-McccItem -LiteralPath $legPath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
          } catch { }
        }
        $allRestoredJarNames.Add($mJar)
      }

      $allNewCulpritJarNames.Add($rootJar)

      # * Clean temp.
      if (Test-Path -LiteralPath $rootTemp) {
        try {
          $null = Remove-McccItem -LiteralPath $rootTemp -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        } catch { }
      }
      if ($null -ne $rootStorageTemp -and (Test-Path -LiteralPath $rootStorageTemp)) {
        try {
          $null = Remove-McccItem -LiteralPath $rootStorageTemp -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        } catch { }
      }
      break
    } else {
      # * Recovery failed. Revert: re-remove culprits, restore root.
      Write-Host ("  Recovery FAILED for {0}. Reverting." -f $rootJar) -ForegroundColor Yellow

      foreach ($mJar in $restoredPaths.Keys) {
        $gamePath = Join-Path -Path $GameModsDir -ChildPath $mJar
        if (Test-Path -LiteralPath $gamePath) {
          try {
            $null = Remove-McccItem -LiteralPath $gamePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
          } catch { }
        }
        if ($useStorage) {
          $storagePath = Join-Path -Path $StorageModsDir -ChildPath $mJar
          if (Test-Path -LiteralPath $storagePath) {
            try {
              $null = Remove-McccItem -LiteralPath $storagePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
            } catch { }
          }
        }
      }

      # * Restore root-cause.
      $restoreRootResult = Move-McccItem -LiteralPath $rootTemp -DestinationPath $rootGamePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
      if (-not $restoreRootResult.Performed) {
        throw ("Failed to restore root-cause mod: {0}" -f $rootGamePath)
      }
      if ($null -ne $rootStorageTemp -and (Test-Path -LiteralPath $rootStorageTemp)) {
        $restoreStorageRootResult = Move-McccItem -LiteralPath $rootStorageTemp -DestinationPath $rootStoragePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        if (-not $restoreStorageRootResult.Performed) {
          throw ("Failed to restore storage root-cause mod: {0}" -f $rootStoragePath)
        }
      }
    }
  }
}

# * Clean up empty temp dirs.
$tempRoot = Get-McccLegacyTempRootPath -ModsDir $GameModsDir -GameLegacyFolderName $GameLegacyFolderName
if (Test-Path -LiteralPath $tempRoot) {
  Get-ChildItem -LiteralPath $tempRoot -Directory -Filter "recovery-*" -ErrorAction SilentlyContinue |
    Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -ErrorAction SilentlyContinue).Count -eq 0 } |
    ForEach-Object {
      try {
        $null = Remove-McccItem -LiteralPath $_.FullName -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
      } catch { }
    }
}

# ────────────────────────────────────────────────────────────────────────────
# * Summary.
# ────────────────────────────────────────────────────────────────────────────

if ($allRestoredJarNames.Count -gt 0) {
  Write-Host ("Recovery complete. Restored {0} mod(s), identified {1} new root-cause culprit(s)." -f $allRestoredJarNames.Count, $allNewCulpritJarNames.Count) -ForegroundColor Green
} elseif ($attempted) {
  Write-Host "Recovery attempted but could not confirm any root-cause swap." -ForegroundColor Yellow
} else {
  Write-Host "Recovery: nothing to attempt." -ForegroundColor Gray
}

$exitCode = if ($allRestoredJarNames.Count -gt 0) { 0 } else { 1 }

if ($EmitResultObject) {
  $stageResultParams = @{
    Stage = "Recovery"
    Type = "RecoveryResult"
    GameModsDir = $GameModsDir
    StorageModsDir = if ($useStorage) { $StorageModsDir } else { "" }
    Minecraft = $Minecraft
    ExitCode = $exitCode
    CulpritJarNames = @($allNewCulpritJarNames)
    CulpritMoves = @()
    ExtraFields = @{
      RestoredJarNames   = @($allRestoredJarNames)
      NewCulpritJarNames = @($allNewCulpritJarNames)
      Attempted          = $attempted
    }
  }
  Write-Output (New-StageResult @stageResultParams)
}

if ($exitCode -eq 0 -and (-not $DryRun)) {
  $finalCrashWindow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
  if ($null -ne $finalCrashWindow) {
    Write-Host ("Closing remaining crash window: {0}" -f $finalCrashWindow.Title) -ForegroundColor Gray
    [void](Close-OutcomeWindowWithExtraDialog -Outcome ([pscustomobject]@{ Type = "CrashDialog"; Window = $finalCrashWindow }) `
      -DelaySeconds $CrashCloseDelaySeconds `
      -OffsetX $CrashCloseClickOffsetX `
      -OffsetY $CrashCloseClickOffsetY `
      -CloseExtraFabricDialogs $true)
  }
}

exit $exitCode
