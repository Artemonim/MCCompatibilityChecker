<#
.SYNOPSIS
Targeted Mixin error analysis: parses crash log for @Mixin errors and tries removing
the source or target mod to fix the crash cheaply (1-2 launches per error).

.DESCRIPTION
Runs BEFORE layering/isolation. Reads the current crash log, extracts Mixin errors,
resolves mod IDs to JAR files via the dependency map, and tests removal of each
candidate with a single game launch. Much faster than brute-force isolation when the
crash is caused by a broken Mixin relationship.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
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
  [string]$LogPath = "",

  [Parameter(Mandatory = $false)]
  [int]$LogMaxAgeMinutes = 30,

  [Parameter(Mandatory = $false)]
  [int]$LogReadRetryCount = 5,

  [Parameter(Mandatory = $false)]
  [int]$LogReadRetryDelayMs = 500,

  [Parameter(Mandatory = $false)]
  [switch]$SkipGameLogs,

  [Parameter(Mandatory = $false)]
  [string[]]$GameProcessNames = @("javaw", "java", "Minecraft"),

  [Parameter(Mandatory = $false)]
  [int]$WaitForGameExitSeconds = 30,

  [Parameter(Mandatory = $false)]
  [int]$GameExitPollSeconds = 2,

  [Parameter(Mandatory = $false)]
  [int]$SuccessConfirmSeconds = 30,

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
  [int]$OutcomeTimeoutSeconds = 90,

  [Parameter(Mandatory = $false)]
  [int]$PollIntervalSeconds = 2,

  [Parameter(Mandatory = $false)]
  [ValidateSet("Tool", "File", "Internal")]
  [string]$DependencyMapSource = "Tool",

  [Parameter(Mandatory = $false)]
  [string]$DependencyMapJsonPath = "",

  [Parameter(Mandatory = $false)]
  [string]$DependencyMapToolPath = "",

  [Parameter(Mandatory = $false)]
  [string]$DependencyMapOutDir = "",

  [Parameter(Mandatory = $false)]
  [switch]$EmitResultObject,

  [Parameter(Mandatory = $false)]
  [int]$MoveRetryCount = 15,

  [Parameter(Mandatory = $false)]
  [int]$MoveRetryDelayMs = 1000,

  [Parameter(Mandatory = $false)]
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
# * Read crash log.
# ────────────────────────────────────────────────────────────────────────────

$logSnapshot = Get-ConfiguredLogSnapshot
if ($null -eq $logSnapshot -or $logSnapshot.Lines.Count -eq 0) {
  Write-Host "Mixin analysis: no crash log available." -ForegroundColor Gray
  if ($EmitResultObject) {
    Write-Output ([pscustomobject]@{ Type = "MixinAnalysisResult"; CulpritJarNames = @(); CulpritMoves = @(); Resolved = $false })
  }
  exit 0
}

$mixinErrors = Get-MixinErrorsFromLog -Lines $logSnapshot.Lines
if ($mixinErrors.Count -eq 0) {
  Write-Host "Mixin analysis: no @Mixin errors found in crash log." -ForegroundColor Gray
  if ($EmitResultObject) {
    Write-Output ([pscustomobject]@{ Type = "MixinAnalysisResult"; CulpritJarNames = @(); CulpritMoves = @(); Resolved = $false })
  }
  exit 0
}

Write-Host ("Mixin analysis: found {0} unique Mixin error(s)." -f $mixinErrors.Count) -ForegroundColor Cyan

# ────────────────────────────────────────────────────────────────────────────
# * Load dependency map for mod ID → JAR resolution.
# ────────────────────────────────────────────────────────────────────────────

$dependencyMap = Get-DependencyMapFromSource -ScanPath $GameModsDir
if ($null -eq $dependencyMap) {
  Write-Host "Mixin analysis: dependency map unavailable. Cannot resolve mod IDs to JARs." -ForegroundColor Yellow
  if ($EmitResultObject) {
    Write-Output ([pscustomobject]@{ Type = "MixinAnalysisResult"; CulpritJarNames = @(); CulpritMoves = @(); Resolved = $false })
  }
  exit 0
}

# * Build mod ID → JAR name lookup and known mod IDs set.
$modIdToJar = @{}
$knownModIds = @{}
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

# ────────────────────────────────────────────────────────────────────────────
# * Resolve candidates and test targeted removal.
# ────────────────────────────────────────────────────────────────────────────

$mcVersionForLegacy = Get-MinecraftVersionFromLog -Lines $logSnapshot.Lines
if ([string]::IsNullOrWhiteSpace($mcVersionForLegacy)) { $mcVersionForLegacy = "unknown" }

$storageLegacyVersionDir = $null
if ($useStorage) {
  $storageLegacyRoot = Join-Path -Path $StorageModsDir -ChildPath $StorageLegacyFolderName
  $storageLegacyVersionDir = Join-Path -Path $storageLegacyRoot -ChildPath $mcVersionForLegacy
}
$gameLegacyVersionDir = $null
if ($KeepCulpritInGameLegacy) {
  $gameLegacyRoot = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
  $gameLegacyVersionDir = Join-Path -Path $gameLegacyRoot -ChildPath $mcVersionForLegacy
}

$culpritJarNames = New-Object System.Collections.Generic.List[string]
$culpritMoves = New-Object System.Collections.Generic.List[pscustomobject]
$mixinConflicts = New-Object System.Collections.Generic.List[pscustomobject]
$resolved = $false

foreach ($mxErr in $mixinErrors) {
  # * Resolve source mod JAR.
  $sourceJar = $null
  if ($modIdToJar.ContainsKey($mxErr.SourceModId)) {
    $sourceJar = $modIdToJar[$mxErr.SourceModId]
  }

  # * Resolve target mod JAR (heuristic: match class segments against known mod IDs).
  $targetModId = Resolve-ModIdFromClassName -ClassName $mxErr.TargetClass -KnownModIds $knownModIds
  $targetJar = $null
  if ($null -ne $targetModId -and $modIdToJar.ContainsKey($targetModId)) {
    $targetJar = $modIdToJar[$targetModId]
  }

  # * Collect conflict info for every Mixin error regardless of resolution outcome.
  $mixinConflicts.Add([pscustomobject]@{
      SourceModId  = $mxErr.SourceModId
      SourceJar    = if ($null -ne $sourceJar) { $sourceJar } else { "" }
      TargetClass  = $mxErr.TargetClass
      TargetModId  = if ($null -ne $targetModId) { $targetModId } else { "" }
      TargetJar    = if ($null -ne $targetJar) { $targetJar } else { "" }
      ErrorLine    = $mxErr.ErrorLine
    })

  Write-Host ("  Mixin error: mod '{0}' → class '{1}'" -f $mxErr.SourceModId, $mxErr.TargetClass) -ForegroundColor Gray
  if ($null -ne $sourceJar) { Write-Host ("    Source JAR: {0}" -f $sourceJar) -ForegroundColor Gray }
  if ($null -ne $targetJar) { Write-Host ("    Target JAR: {0} (mod: {1})" -f $targetJar, $targetModId) -ForegroundColor Gray }

  # * Try candidates: source first, then target.
  $candidates = @()
  if ($null -ne $sourceJar) { $candidates += $sourceJar }
  if ($null -ne $targetJar -and $targetJar -ne $sourceJar) { $candidates += $targetJar }

  foreach ($candJar in $candidates) {
    $gamePath = Join-Path -Path $GameModsDir -ChildPath $candJar
    if (-not (Test-Path -LiteralPath $gamePath)) {
      Write-Host ("    Skipping {0}: not found in game mods." -f $candJar) -ForegroundColor Gray
      continue
    }

    Write-Host ("    Testing removal of: {0}" -f $candJar) -ForegroundColor Cyan

    if ($DryRun) {
      Write-Host "    DRYRUN: would remove and test." -ForegroundColor Gray
      continue
    }

    # * Quarantine the candidate.
    $tempDir = Join-Path -Path $GameModsDir -ChildPath ("{0}\temp\mixin-{1}" -f $GameLegacyFolderName, (Get-Date -Format "yyyyMMdd-HHmmss"))
    if (-not (Test-Path -LiteralPath $tempDir)) {
      New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    $tempDest = Join-Path -Path $tempDir -ChildPath $candJar
    Move-Item -LiteralPath $gamePath -Destination $tempDest -Force

    $storageTemp = $null
    $storagePath = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $candJar } else { $null }
    if ($useStorage -and $storagePath -and (Test-Path -LiteralPath $storagePath)) {
      $storageTemp = Join-Path -Path $tempDir -ChildPath ("storage-{0}" -f $candJar)
      Move-Item -LiteralPath $storagePath -Destination $storageTemp -Force
    }

    $isSuccess = $false
    try {
      # * Close any stray crash dialogs.
      $strayCrash = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
      if ($null -ne $strayCrash) {
        Write-Host ("    Closing stray crash dialog: {0}" -f $strayCrash.Title) -ForegroundColor Gray
        Invoke-WindowClose -Handle $strayCrash.Handle
        Start-Sleep -Seconds 2
      }

      # * Launch game.
      $launchStart = Get-Date
      $outcome = Invoke-ConfiguredLaunchAttempt
      Write-Host ("    Outcome: {0}" -f $outcome.Type) -ForegroundColor Gray

      if ($outcome.Type -eq "Timeout") {
        # * Wait for stability confirmation.
        Write-Host ("    Confirming stability ({0}s)..." -f $SuccessConfirmSeconds) -ForegroundColor Gray
        Start-Sleep -Seconds $SuccessConfirmSeconds
        $crashNow = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
        if ($null -eq $crashNow) {
          $isSuccess = $true
        } else {
          Invoke-WindowClose -Handle $crashNow.Handle
        }
        # * Kill game process.
        [void](Stop-ConfiguredGameProcess -StartedAfter $launchStart)
      }

      if ($outcome.Type -eq "CrashDialog" -and $null -ne $outcome.Window) {
        Invoke-WindowClose -Handle $outcome.Window.Handle
      }
      if ($outcome.Type -eq "FabricDialog" -and $null -ne $outcome.Window) {
        Invoke-WindowClose -Handle $outcome.Window.Handle
      }

      # * Close post-outcome crash dialogs.
      Start-Sleep -Seconds 2
      $postCrash = Select-WindowByTitlePattern -Patterns $CrashWindowTitlePatterns
      if ($null -ne $postCrash) {
        Invoke-WindowClose -Handle $postCrash.Handle
      }
    } catch {
      # ! Error during launch/test — restore quarantined mod and re-throw.
      Write-Host ("    Error during Mixin test: {0}. Rolling back." -f $_.Exception.Message) -ForegroundColor Red
      if (Test-Path -LiteralPath $tempDest) {
        Move-Item -LiteralPath $tempDest -Destination $gamePath -Force -ErrorAction SilentlyContinue
      }
      if ($null -ne $storageTemp -and (Test-Path -LiteralPath $storageTemp) -and $null -ne $storagePath) {
        Move-Item -LiteralPath $storageTemp -Destination $storagePath -Force -ErrorAction SilentlyContinue
      }
      throw
    }

    if ($isSuccess) {
      Write-Host ("    Confirmed: removing {0} fixes the Mixin crash." -f $candJar) -ForegroundColor Green

      # * Move to legacy.
      $culpritStorageLegacy = $null
      $culpritGameLegacy = $null

      if ($useStorage -and $null -ne $storageLegacyVersionDir) {
        if (-not (Test-Path -LiteralPath $storageLegacyVersionDir)) {
          New-Item -ItemType Directory -Path $storageLegacyVersionDir -Force | Out-Null
        }
        $srcFile = if ($null -ne $storageTemp -and (Test-Path -LiteralPath $storageTemp)) { $storageTemp } else { $tempDest }
        $destPath = Join-Path -Path $storageLegacyVersionDir -ChildPath $candJar
        Copy-Item -LiteralPath $srcFile -Destination $destPath -Force
        $culpritStorageLegacy = $destPath
        Write-Host ("Moved culprit to storage legacy: {0}" -f $destPath) -ForegroundColor Green
        $legacyLogEntry = "Moved culprit to storage legacy: {0}" -f $destPath
        Add-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "legacy.log") -Value $legacyLogEntry -ErrorAction SilentlyContinue
      }

      if ($KeepCulpritInGameLegacy -and $null -ne $gameLegacyVersionDir) {
        if (-not (Test-Path -LiteralPath $gameLegacyVersionDir)) {
          New-Item -ItemType Directory -Path $gameLegacyVersionDir -Force | Out-Null
        }
        $destPath = Join-Path -Path $gameLegacyVersionDir -ChildPath $candJar
        Move-Item -LiteralPath $tempDest -Destination $destPath -Force
        $culpritGameLegacy = $destPath
        Write-Host ("Moved culprit to game legacy: {0}" -f $destPath) -ForegroundColor Green
      }

      # * Clean up temp storage copy.
      if ($null -ne $storageTemp -and (Test-Path -LiteralPath $storageTemp)) {
        Remove-Item -LiteralPath $storageTemp -Force -ErrorAction SilentlyContinue
      }
      # * Clean up temp game copy if not already moved.
      if (Test-Path -LiteralPath $tempDest) {
        Remove-Item -LiteralPath $tempDest -Force -ErrorAction SilentlyContinue
      }

      $culpritJarNames.Add($candJar)
      $culpritMoves.Add([pscustomobject]@{
          JarName            = $candJar
          GameModsDir        = $GameModsDir
          StorageModsDir     = if ($useStorage) { $StorageModsDir } else { "" }
          StorageLegacyPath  = $culpritStorageLegacy
          GameLegacyPath     = $culpritGameLegacy
          Minecraft          = $mcVersionForLegacy
          KeepCulpritInGameLegacy = [bool]$KeepCulpritInGameLegacy
          CrashEvidenceKey   = $mxErr.ErrorLine
          Stage              = "mixin-analysis"
        })
      Write-Host ("Culprit identified: {0}" -f $candJar) -ForegroundColor Green
      $resolved = $true
      break
    } else {
      # * Restore the candidate.
      Write-Host ("    {0} did not fix the crash. Restoring." -f $candJar) -ForegroundColor Gray
      Move-Item -LiteralPath $tempDest -Destination $gamePath -Force
      if ($null -ne $storageTemp -and (Test-Path -LiteralPath $storageTemp)) {
        Move-Item -LiteralPath $storageTemp -Destination $storagePath -Force
      }
    }
  }

  if ($resolved) { break }
}

# * Clean up empty temp dirs.
$tempRoot = Join-Path -Path $GameModsDir -ChildPath ("{0}\temp" -f $GameLegacyFolderName)
if (Test-Path -LiteralPath $tempRoot) {
  Get-ChildItem -LiteralPath $tempRoot -Directory -Filter "mixin-*" -ErrorAction SilentlyContinue |
    Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -ErrorAction SilentlyContinue).Count -eq 0 } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

# ────────────────────────────────────────────────────────────────────────────
# * Summary.
# ────────────────────────────────────────────────────────────────────────────

if ($culpritJarNames.Count -gt 0) {
  Write-Host ("Mixin analysis resolved {0} culprit(s): {1}" -f $culpritJarNames.Count, ($culpritJarNames -join ", ")) -ForegroundColor Green
} else {
  Write-Host "Mixin analysis could not resolve the crash by targeted removal." -ForegroundColor Yellow
}

if ($mixinConflicts.Count -gt 0) {
  Write-Host ("Mixin analysis detected {0} mod conflict(s):" -f $mixinConflicts.Count) -ForegroundColor Cyan
  foreach ($conflict in $mixinConflicts) {
    $srcLabel = if (-not [string]::IsNullOrWhiteSpace($conflict.SourceJar)) { $conflict.SourceJar } else { $conflict.SourceModId }
    $tgtLabel = if (-not [string]::IsNullOrWhiteSpace($conflict.TargetModId)) { $conflict.TargetModId } else { $conflict.TargetClass }
    Write-Host ("  {0} (mod: {1}) targets missing class in {2}" -f $srcLabel, $conflict.SourceModId, $tgtLabel) -ForegroundColor Gray
  }
}

if ($EmitResultObject) {
  Write-Output ([pscustomobject]@{
      Type             = "MixinAnalysisResult"
      CulpritJarNames  = @($culpritJarNames)
      CulpritMoves     = @($culpritMoves.ToArray())
      MixinConflicts   = @($mixinConflicts.ToArray())
      Resolved         = $resolved
      GameModsDir      = $GameModsDir
      StorageModsDir   = if ($useStorage) { $StorageModsDir } else { "" }
      Minecraft        = $mcVersionForLegacy
    })
}

exit $(if ($resolved) { 0 } else { 1 })
