# * Restore-ModsFromLog.ps1
# * Restores mods moved to storage/game legacy based on legacy.log entries.

[CmdletBinding()]
param(
  # * Optional: restore only entries at or after this timestamp.
  [Parameter(Mandatory = $false)]
  [datetime]$SinceTimestamp = [datetime]::MinValue,

  # * Optional: avoid terminating the caller; sets $LASTEXITCODE instead.
  [Parameter(Mandatory = $false)]
  [switch]$NoExit
)

$sharedBootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\Shared-Bootstrap.ps1"
if (-not (Test-Path -LiteralPath $sharedBootstrapPath)) {
  throw ("Shared bootstrap helpers not found: {0}" -f $sharedBootstrapPath)
}
. $sharedBootstrapPath
. Initialize-McccRuntimeBootstrap `
  -StartDir $PSScriptRoot `
  -InitializeLocalization `
  -EnableConsoleLocalization `
  -LocalizationNotFoundMessage "Shared localization helpers not found: {0}" | Out-Null

function Complete-Restore {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ExitCode,
    [Parameter(Mandatory = $false)]
    [switch]$NoExit
  )

  $global:LASTEXITCODE = $ExitCode
  if ($NoExit) { return }
  exit $ExitCode
}

$sharedToolPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Restore-ModsFromLog.ps1"
if (-not (Test-Path -LiteralPath $sharedToolPath)) {
  Write-Error ("Shared restore tool helpers not found at: {0}" -f $sharedToolPath)
  Complete-Restore -ExitCode 1 -NoExit:$NoExit
  return
}
. $sharedToolPath

# * Load shared config.
$sharedConfigPath = Get-McccSharedScriptPath -StartDir $PSScriptRoot -RelativePath "Shared-Config.ps1"
if (Test-Path -LiteralPath $sharedConfigPath) {
  . $sharedConfigPath
} else {
  Write-Error ("Shared config not found at: {0}" -f $sharedConfigPath)
  Complete-Restore -ExitCode 1 -NoExit:$NoExit
  return
}

# * Load shared restore helper.
$restoreHelperPath = Get-McccSharedScriptPath -StartDir $PSScriptRoot -RelativePath "Auto-Run-LegacyLauncher.Restore.ps1"
if (Test-Path -LiteralPath $restoreHelperPath) {
  . $restoreHelperPath
} else {
  Write-Error ("Warning: restore script not found: {0}" -f $restoreHelperPath)
  Complete-Restore -ExitCode 1 -NoExit:$NoExit
  return
}

if (-not (Get-Command -Name Restore-IsolationCulpritMod -ErrorAction SilentlyContinue)) {
  Write-Error ("Warning: auto-restore failed: {0}" -f $restoreHelperPath)
  Complete-Restore -ExitCode 1 -NoExit:$NoExit
  return
}

$config = Import-ProjectConfig -StartDir $PSScriptRoot
$ini = $config.Ini
$projectRoot = Get-McccBootstrapProjectRoot -StartDir $PSScriptRoot -ProjectConfig $config

# * Reads from legacy.log (persistent append-only culprit log).
$logPath = Join-Path $projectRoot "legacy.log"
$storageModsDir = Get-IniValue -Ini $ini -Section "Paths" -Key "StorageModsDir" -Default "D:\Установщики игр\MineCraft 1.21\Mods"
$gameModsDir = Get-IniValue -Ini $ini -Section "Paths" -Key "GameModsDir" -Default "$env:APPDATA\.tlauncher\legacy\Minecraft\game\mods"

# * Keep restore deterministic when StorageModsDir is intentionally empty in config.
if ([string]::IsNullOrWhiteSpace($storageModsDir) -and -not [string]::IsNullOrWhiteSpace($gameModsDir)) {
  $storageModsDir = $gameModsDir
}

if (-not (Test-Path -LiteralPath $logPath)) {
  Write-Error ("Log file not found at: {0}" -f $logPath)
  Complete-Restore -ExitCode 1 -NoExit:$NoExit
  return
}

$logContent = Get-Content -LiteralPath $logPath -ErrorAction Stop
$parsedLog = Get-McccLegacyLogCulpritMoves `
  -LogLines @($logContent) `
  -SinceTimestamp $SinceTimestamp `
  -GameModsDir $gameModsDir `
  -StorageModsDir $storageModsDir

$effectiveSinceTimestamp = [datetime]$parsedLog.EffectiveSinceTimestamp
if ($effectiveSinceTimestamp -ne [datetime]::MinValue) {
  Write-Host ("Filtering legacy log entries after: {0}" -f $effectiveSinceTimestamp.ToString("yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
}

$culpritMoves = @($parsedLog.CulpritMoves)
if ($culpritMoves.Count -eq 0) {
  if ($effectiveSinceTimestamp -ne [datetime]::MinValue) {
    Write-Host ("No culprits found to restore in the log after {0}." -f $effectiveSinceTimestamp.ToString("yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
  } else {
    Write-Host "No culprits found to restore in the log." -ForegroundColor Gray
  }
  Complete-Restore -ExitCode 0 -NoExit:$NoExit
  return
}

Write-Host ("Found {0} culprit(s) to restore." -f $culpritMoves.Count) -ForegroundColor Cyan
$restoreDetails = Restore-IsolationCulpritMod -CulpritMoves $culpritMoves -ReturnDetails

if ($null -eq $restoreDetails) {
  Write-Error ("Warning: auto-restore failed: {0}" -f $restoreHelperPath)
  Complete-Restore -ExitCode 1 -NoExit:$NoExit
  return
}

$failedJarNames = @($restoreDetails.FailedJarNames)
$failedCount = $failedJarNames.Count
if ($failedCount -gt 0) {
  $failedLabel = if ($failedJarNames.Count -gt 0) { $failedJarNames -join ", " } else { [string]$failedCount }
  Write-Warning ("Warning: auto-restore failed: {0}" -f $failedLabel)
}

Write-Host "Restore process completed." -ForegroundColor Green
$exitCode = if ([bool]$restoreDetails.Success) { 0 } else { 1 }
Complete-Restore -ExitCode $exitCode -NoExit:$NoExit
return
