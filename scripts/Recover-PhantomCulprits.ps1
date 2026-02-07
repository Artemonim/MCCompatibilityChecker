<#
.SYNOPSIS
Post-isolation recovery: detects culprits that share the same Mixin error and
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
  [string]$GameLegacyFolderName = "legacy",

  [Parameter(Mandatory = $false)]
  [string]$StorageModsDir = "",

  [Parameter(Mandatory = $false)]
  [string]$StorageLegacyFolderName = "Legacy",

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
  [string[]]$PlayButtonNames = @("Запустить", "Play", "Start"),

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
  [string[]]$CrashWindowTitlePatterns = @("Что-то сломалось"),

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

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# * Launch wait scaling config.
$launchWaitBaseSeconds = 20
$launchWaitPerModSeconds = 0.1

function Get-ActiveModCount {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModsDir
  )

  if ([string]::IsNullOrWhiteSpace($ModsDir)) { return 0 }
  if (-not (Test-Path -LiteralPath $ModsDir)) { return 0 }
  $mods = Get-ChildItem -LiteralPath $ModsDir -Filter "*.jar" -File -ErrorAction SilentlyContinue
  if ($null -eq $mods) { return 0 }
  return @($mods).Count
}

function Get-ScaledLaunchWaitTime {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ActiveModCount,
    [Parameter(Mandatory = $true)]
    [double]$PerModSeconds,
    [Parameter(Mandatory = $true)]
    [int]$BaseSeconds
  )

  $rawSeconds = $BaseSeconds + ($ActiveModCount * $PerModSeconds)
  $scaledSeconds = [int][Math]::Ceiling($rawSeconds)
  if ($scaledSeconds -lt $BaseSeconds) { $scaledSeconds = $BaseSeconds }
  return $scaledSeconds
}

$useDynamicOutcomeTimeout = -not $PSBoundParameters.ContainsKey("OutcomeTimeoutSeconds")
$useDynamicSuccessConfirm = -not $PSBoundParameters.ContainsKey("SuccessConfirmSeconds")

# ────────────────────────────────────────────────────────────────────────────
# * Load shared modules.
# ────────────────────────────────────────────────────────────────────────────

$sharedConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Config.ps1"
. $sharedConfigPath
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

$projectConfig = Import-ProjectConfig -StartDir $PSScriptRoot
$configIni = $projectConfig.Ini

if ([string]::IsNullOrWhiteSpace($GameModsDir)) {
  $GameModsDir = Get-IniValue -Ini $configIni -Section "Paths" -Key "GameModsDir" -Default (Join-Path -Path ([Environment]::GetFolderPath('ApplicationData')) -ChildPath '.tlauncher\legacy\Minecraft\game\mods')
}
if ([string]::IsNullOrWhiteSpace($StorageModsDir)) {
  $StorageModsDir = Get-IniValue -Ini $configIni -Section "Paths" -Key "StorageModsDir" -Default ""
}
$useStorage = -not [string]::IsNullOrWhiteSpace($StorageModsDir)

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
    Write-Output ([pscustomobject]@{ Type = "RecoveryResult"; RestoredJarNames = @(); NewCulpritJarNames = @(); Attempted = $false })
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
    Write-Output ([pscustomobject]@{ Type = "RecoveryResult"; RestoredJarNames = @(); NewCulpritJarNames = @(); Attempted = $false })
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

$storageLegacyVersionDir = $null
if ($useStorage) {
  $storageLegacyRoot = Join-Path -Path $StorageModsDir -ChildPath $StorageLegacyFolderName
  $storageLegacyVersionDir = Join-Path -Path $storageLegacyRoot -ChildPath $Minecraft
}
$gameLegacyVersionDir = $null
if ($KeepCulpritInGameLegacy) {
  $gameLegacyRoot = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
  $gameLegacyVersionDir = Join-Path -Path $gameLegacyRoot -ChildPath $Minecraft
}

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
    $tempDir = Join-Path -Path $GameModsDir -ChildPath ("{0}\temp\recovery-{1}" -f $GameLegacyFolderName, (Get-Date -Format "yyyyMMdd-HHmmss"))
    if (-not (Test-Path -LiteralPath $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
    $rootTemp = Join-Path -Path $tempDir -ChildPath $rootJar
    Move-Item -LiteralPath $rootGamePath -Destination $rootTemp -Force
    Write-Host ("  Quarantined root-cause: {0}" -f $rootJar) -ForegroundColor Gray

    $rootStorageTemp = $null
    $rootStoragePath = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $rootJar } else { $null }
    if ($useStorage -and $rootStoragePath -and (Test-Path -LiteralPath $rootStoragePath)) {
      $rootStorageTemp = Join-Path -Path $tempDir -ChildPath ("storage-{0}" -f $rootJar)
      Move-Item -LiteralPath $rootStoragePath -Destination $rootStorageTemp -Force
    }

    # * Step 2: Restore all phantom culprits back to game mods.
    $restoredPaths = @{}
    foreach ($member in $group.Members) {
      $mJar = [string]$member.JarName
      $gameTarget = Join-Path -Path $GameModsDir -ChildPath $mJar

      # * Restore from storage legacy (copy).
      $sLeg = [string]$member.StorageLegacyPath
      if (-not [string]::IsNullOrWhiteSpace($sLeg) -and (Test-Path -LiteralPath $sLeg)) {
        Copy-Item -LiteralPath $sLeg -Destination $gameTarget -Force
        if ($useStorage) {
          $storageTarget = Join-Path -Path $StorageModsDir -ChildPath $mJar
          Copy-Item -LiteralPath $sLeg -Destination $storageTarget -Force
        }
        $restoredPaths[$mJar] = $sLeg
        Write-Host ("  Restored: {0}" -f $mJar) -ForegroundColor Gray
        continue
      }

      # * Restore from game legacy.
      $gLeg = [string]$member.GameLegacyPath
      if (-not [string]::IsNullOrWhiteSpace($gLeg) -and (Test-Path -LiteralPath $gLeg)) {
        Copy-Item -LiteralPath $gLeg -Destination $gameTarget -Force
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
        # * Give launcher/crash UI time to present after java exit.
        Start-Sleep -Seconds 2
        $crashAfterExit = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
        if ($null -ne $crashAfterExit) {
          Write-Host ("  Detected crash dialog after ProcessExit: {0}" -f $crashAfterExit.Title) -ForegroundColor Yellow
          $outcome = [pscustomobject]@{
            Type = "CrashDialog"
            Window = $crashAfterExit
          }
        }
      }

      Write-Host ("  Outcome: {0}" -f $outcome.Type) -ForegroundColor Gray

      if ($outcome.Type -eq "Timeout") {
        Start-Sleep -Seconds $effectiveConfirmSeconds
        $crashNow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
        if ($null -eq $crashNow) {
          $isSuccess = $true
        } else {
          Invoke-WindowClose -Handle $crashNow.Handle
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

      Start-Sleep -Seconds 2
      $postCrash = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
      if ($null -ne $postCrash) {
        $script:lastOutcomeHandleId = Close-OutcomeWindowWithExtraDialog `
          -Outcome ([pscustomobject]@{ Type = "CrashDialog"; Window = $postCrash }) `
          -DelaySeconds $CrashCloseDelaySeconds `
          -OffsetX $CrashCloseClickOffsetX `
          -OffsetY $CrashCloseClickOffsetY `
          -CloseExtraFabricDialogs $true
      }
    } catch {
      # ! Error during launch/verification — revert all changes and re-throw.
      Write-Host ("  Error during recovery verification: {0}. Rolling back." -f $_.Exception.Message) -ForegroundColor Red
      foreach ($mJar in $restoredPaths.Keys) {
        $mGamePath = Join-Path -Path $GameModsDir -ChildPath $mJar
        if (Test-Path -LiteralPath $mGamePath) {
          Remove-Item -LiteralPath $mGamePath -Force -ErrorAction SilentlyContinue
        }
        if ($useStorage) {
          $mStoragePath = Join-Path -Path $StorageModsDir -ChildPath $mJar
          if (Test-Path -LiteralPath $mStoragePath) {
            Remove-Item -LiteralPath $mStoragePath -Force -ErrorAction SilentlyContinue
          }
        }
      }
      if (Test-Path -LiteralPath $rootTemp) {
        Move-Item -LiteralPath $rootTemp -Destination $rootGamePath -Force -ErrorAction SilentlyContinue
      }
      if ($null -ne $rootStorageTemp -and (Test-Path -LiteralPath $rootStorageTemp) -and $null -ne $rootStoragePath) {
        Move-Item -LiteralPath $rootStorageTemp -Destination $rootStoragePath -Force -ErrorAction SilentlyContinue
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
      if ($useStorage -and $null -ne $storageLegacyVersionDir) {
        if (-not (Test-Path -LiteralPath $storageLegacyVersionDir)) {
          New-Item -ItemType Directory -Path $storageLegacyVersionDir -Force | Out-Null
        }
        $destPath = Join-Path -Path $storageLegacyVersionDir -ChildPath $rootJar
        $srcFile = if ($null -ne $rootStorageTemp -and (Test-Path -LiteralPath $rootStorageTemp)) { $rootStorageTemp } else { $rootTemp }
        Copy-Item -LiteralPath $srcFile -Destination $destPath -Force
        Write-Host ("Moved culprit to storage legacy: {0}" -f $destPath) -ForegroundColor Green
        $legacyLogEntry = "Moved culprit to storage legacy: {0}" -f $destPath
        Add-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "legacy.log") -Value $legacyLogEntry -ErrorAction SilentlyContinue
      }
      if ($KeepCulpritInGameLegacy -and $null -ne $gameLegacyVersionDir) {
        if (-not (Test-Path -LiteralPath $gameLegacyVersionDir)) {
          New-Item -ItemType Directory -Path $gameLegacyVersionDir -Force | Out-Null
        }
        $destPath = Join-Path -Path $gameLegacyVersionDir -ChildPath $rootJar
        Copy-Item -LiteralPath $rootTemp -Destination $destPath -Force
        Write-Host ("Moved culprit to game legacy: {0}" -f $destPath) -ForegroundColor Green
      }

      # * Remove original legacy copies of restored culprits.
      foreach ($mJar in $restoredPaths.Keys) {
        $legPath = $restoredPaths[$mJar]
        if (Test-Path -LiteralPath $legPath) {
          Remove-Item -LiteralPath $legPath -Force -ErrorAction SilentlyContinue
        }
        $allRestoredJarNames.Add($mJar)
      }

      $allNewCulpritJarNames.Add($rootJar)

      # * Clean temp.
      if (Test-Path -LiteralPath $rootTemp) { Remove-Item -LiteralPath $rootTemp -Force -ErrorAction SilentlyContinue }
      if ($null -ne $rootStorageTemp -and (Test-Path -LiteralPath $rootStorageTemp)) {
        Remove-Item -LiteralPath $rootStorageTemp -Force -ErrorAction SilentlyContinue
      }
      break
    } else {
      # * Recovery failed. Revert: re-remove culprits, restore root.
      Write-Host ("  Recovery FAILED for {0}. Reverting." -f $rootJar) -ForegroundColor Yellow

      foreach ($mJar in $restoredPaths.Keys) {
        $gamePath = Join-Path -Path $GameModsDir -ChildPath $mJar
        if (Test-Path -LiteralPath $gamePath) {
          Remove-Item -LiteralPath $gamePath -Force -ErrorAction SilentlyContinue
        }
        if ($useStorage) {
          $storagePath = Join-Path -Path $StorageModsDir -ChildPath $mJar
          if (Test-Path -LiteralPath $storagePath) {
            Remove-Item -LiteralPath $storagePath -Force -ErrorAction SilentlyContinue
          }
        }
      }

      # * Restore root-cause.
      Move-Item -LiteralPath $rootTemp -Destination $rootGamePath -Force
      if ($null -ne $rootStorageTemp -and (Test-Path -LiteralPath $rootStorageTemp)) {
        Move-Item -LiteralPath $rootStorageTemp -Destination $rootStoragePath -Force
      }
    }
  }
}

# * Clean up empty temp dirs.
$tempRoot = Join-Path -Path $GameModsDir -ChildPath ("{0}\temp" -f $GameLegacyFolderName)
if (Test-Path -LiteralPath $tempRoot) {
  Get-ChildItem -LiteralPath $tempRoot -Directory -Filter "recovery-*" -ErrorAction SilentlyContinue |
    Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -ErrorAction SilentlyContinue).Count -eq 0 } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
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

if ($EmitResultObject) {
  Write-Output ([pscustomobject]@{
      Type                = "RecoveryResult"
      RestoredJarNames    = @($allRestoredJarNames)
      NewCulpritJarNames  = @($allNewCulpritJarNames)
      Attempted           = $attempted
    })
}

exit $(if ($allRestoredJarNames.Count -gt 0) { 0 } else { 1 })
