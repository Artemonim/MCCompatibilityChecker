<#
.SYNOPSIS
Update-mode pipeline for staged mod updates from StorageModsDir.

.DESCRIPTION
Runs a preflight launch check, applies updates for the anchor jar and newer jars
from StorageModsDir, replaces matching older versions in GameModsDir, moves old
storage versions to Updated, and verifies launch stability.

If preflight launch already fails with Crash/NoLaunch, offers a modal decision:
- Eliminate: run the standard pipeline (Auto-Run-LegacyLauncher.ps1).
- Cancel: stop without changes.

If launch fails after applying updates, attempts:
1) targeted rollback restores from Updated,
2) additive rollback layering,
3) rollback minimization (remove unnecessary old jars).

.PARAMETER UpdatePath
Path to an anchor .jar file inside StorageModsDir root.
The anchor jar is included in processing together with all jars whose
LastWriteTime is newer or equal to the anchor.

.PARAMETER RemainingArgs
Additional args forwarded to standard pipeline when fallback is selected.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
  [Parameter(Mandatory = $true)]
  [Alias("Update")]
  [string]$UpdatePath,

  [Parameter(Mandatory = $false)]
  [string]$LauncherExePath = "",

  [Parameter(Mandatory = $false)]
  [string[]]$LauncherArguments = @(),

  [Parameter(Mandatory = $false)]
  [Alias("Auto")]
  [bool]$UseAutoLaunch = $true,

  [Parameter(Mandatory = $false)]
  [switch]$DisableAutoLaunch,

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
  [int]$CrashCloseClickOffsetX = -1,

  [Parameter(Mandatory = $false)]
  [int]$CrashCloseClickOffsetY = -1,

  [Parameter(Mandatory = $false)]
  [int]$CrashCloseDelaySeconds = 5,

  [Parameter(Mandatory = $false)]
  [string[]]$CrashWindowTitlePatterns = @("Something broke"),

  [Parameter(Mandatory = $false)]
  [string[]]$FabricWindowTitlePatterns = @("Fabric Loader", "owo-sentinel"),

  [Parameter(Mandatory = $false)]
  [bool]$AutoHandleFabricDialog = $true,

  [Parameter(Mandatory = $false)]
  [string]$LogPath = "",

  [Parameter(Mandatory = $false)]
  [int]$LauncherWindowTimeoutSeconds = 60,

  [Parameter(Mandatory = $false)]
  [int]$OutcomeTimeoutSeconds = 60,

  [Parameter(Mandatory = $false)]
  [int]$PollIntervalSeconds = 2,

  [Parameter(Mandatory = $false)]
  [int]$SuccessGraceSeconds = 15,

  [Parameter(Mandatory = $false)]
  [string[]]$GameProcessNames = @("javaw", "java", "Minecraft"),

  [Parameter(Mandatory = $false)]
  [int]$WaitForGameExitSeconds = 30,

  [Parameter(Mandatory = $false)]
  [int]$GameExitPollSeconds = 2,

  [Parameter(Mandatory = $false)]
  [bool]$DeleteFromGameMods = $true,

  [Parameter(Mandatory = $false)]
  [switch]$NoLegacy,

  [Parameter(Mandatory = $false)]
  [switch]$GameLegacy,

  [Parameter(Mandatory = $false)]
  [switch]$UseLinearIsolation,

  [Parameter(Mandatory = $false)]
  [int]$BinaryLinearThreshold = 0,

  [Parameter(Mandatory = $false)]
  [switch]$ThoroughStabilityCheck,

  [Parameter(Mandatory = $false)]
  [switch]$NoCache,

  [Parameter(Mandatory = $false)]
  [string[]]$IgnoreModIds = @(),

  [Parameter(Mandatory = $false)]
  [string[]]$CheckScriptArguments = @(),

  [Parameter(Mandatory = $false)]
  [string[]]$IsolateScriptArguments = @(),

  [Parameter(Mandatory = $false)]
  [Alias("Profile")]
  [string]$ProfileName = "",

  [Parameter(Mandatory = $false)]
  [switch]$DryRun,

  [Parameter(Mandatory = $false)]
  [switch]$Help,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArgs = @()
)

$sharedBootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Bootstrap.ps1"
if (-not (Test-Path -LiteralPath $sharedBootstrapPath)) {
  throw ("Shared bootstrap helpers not found: {0}" -f $sharedBootstrapPath)
}
. $sharedBootstrapPath
$runtimeBootstrap = . Initialize-McccRuntimeBootstrap `
  -StartDir $PSScriptRoot `
  -LoadConfig `
  -InitializeLocalization `
  -EnableConsoleLocalization `
  -ConfigNotFoundMessage "Shared config helpers not found: {0}" `
  -LocalizationNotFoundMessage "Shared localization helpers not found: {0}"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Help) {
  Get-Help -Full -Name $PSCommandPath
  return
}

$profileTypeMap = @{
  LauncherWindowTitlePattern = "string"
  PlayButtonNames = "string[]"
  PlayClickOffsetX = "int"
  PlayClickOffsetY = "int"
  PlayClickDelayMs = "int"
  PlayClickMaxAttempts = "int"
  CrashWindowTitlePatterns = "string[]"
  FabricWindowTitlePatterns = "string[]"
  CrashCloseClickOffsetX = "int"
  CrashCloseClickOffsetY = "int"
  CrashCloseDelaySeconds = "int"
  AutoHandleFabricDialog = "bool"
  IgnoreModIds = "string[]"
  LauncherWindowTimeoutSeconds = "int"
  OutcomeTimeoutSeconds = "int"
  PollIntervalSeconds = "int"
  SuccessGraceSeconds = "int"
  GameProcessNames = "string[]"
}
$projectConfig = $runtimeBootstrap.ProjectConfig
if ($null -eq $projectConfig) {
  $projectConfig = Import-ProjectConfig -StartDir $PSScriptRoot
}
$configIni = $projectConfig.Ini
$profileOverrides = Get-ProfileOverride `
  -Ini $configIni `
  -BoundParameters $PSBoundParameters `
  -ProfileName $ProfileName `
  -KeyTypeMap $profileTypeMap
foreach ($key in $profileOverrides.Keys) {
  Set-Variable -Name $key -Value $profileOverrides[$key] -Scope Local
}

if (-not $PSBoundParameters.ContainsKey("CrashWindowTitlePatterns") -and (-not $profileOverrides.ContainsKey("CrashWindowTitlePatterns"))) {
  $CrashWindowTitlePatterns = Get-McccLocaleCrashWindowTitlePatternSet -StartDir $PSScriptRoot -FallbackPatterns $CrashWindowTitlePatterns
}

$runtimeConfig = Initialize-McccRuntimeConfig `
  -StartDir $PSScriptRoot `
  -BoundParameters $PSBoundParameters `
  -LogPath $LogPath `
  -LauncherExePath $LauncherExePath `
  -AlwaysDefaultGameModsDir $false `
  -DefaultStorageToGame $false
$GameModsDir = [string]$runtimeConfig.Paths.GameModsDir
$StorageModsDir = [string]$runtimeConfig.Paths.StorageModsDir
$LogPath = [string]$runtimeConfig.Paths.LogPath
$LauncherExePath = [string]$runtimeConfig.Paths.LauncherExePath

$sharedUiPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LauncherUi.ps1"
if (-not (Test-Path -LiteralPath $sharedUiPath)) { throw ("Shared UI helpers not found: {0}" -f $sharedUiPath) }
. $sharedUiPath

$sharedLogPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LogTools.ps1"
if (-not (Test-Path -LiteralPath $sharedLogPath)) { throw ("Shared log helpers not found: {0}" -f $sharedLogPath) }
. $sharedLogPath

$sharedFileOpsPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-FileOps.ps1"
if (-not (Test-Path -LiteralPath $sharedFileOpsPath)) { throw ("Shared file operation helpers not found: {0}" -f $sharedFileOpsPath) }
. $sharedFileOpsPath

$sharedJarToolsPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-JarTools.ps1"
if (-not (Test-Path -LiteralPath $sharedJarToolsPath)) { throw ("Shared jar helpers not found: {0}" -f $sharedJarToolsPath) }
. $sharedJarToolsPath

$sharedJarMetadataPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-JarMetadata.ps1"
if (-not (Test-Path -LiteralPath $sharedJarMetadataPath)) { throw ("Shared jar metadata helpers not found: {0}" -f $sharedJarMetadataPath) }
. $sharedJarMetadataPath

$sharedIsolationLauncherPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Launcher.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationLauncherPath)) { throw ("Shared isolation launcher helpers not found: {0}" -f $sharedIsolationLauncherPath) }
. $sharedIsolationLauncherPath

$sharedIsolationLogPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-LogParsing.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationLogPath)) { throw ("Shared isolation log helpers not found: {0}" -f $sharedIsolationLogPath) }
. $sharedIsolationLogPath

$SkipGameLogs = $false
$LogMaxAgeMinutes = 30
$LogReadRetryCount = 5
$LogReadRetryDelayMs = 500

function Write-UpdateStage {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  Write-Host ("`n[Update] {0}" -f $Name) -ForegroundColor Cyan
}

function Test-ModIdOverlap {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$Left = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$Right = @()
  )

  if (-not $Left -or $Left.Count -eq 0) { return $false }
  if (-not $Right -or $Right.Count -eq 0) { return $false }
  $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($item in @($Left)) {
    $value = [string]$item
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    $null = $set.Add($value.Trim().ToLowerInvariant())
  }
  foreach ($item in @($Right)) {
    $value = [string]$item
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    if ($set.Contains($value.Trim().ToLowerInvariant())) { return $true }
  }
  return $false
}

function New-UpdateJarInfo {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.FileInfo]$File,
    [Parameter(Mandatory = $true)]
    [hashtable]$MetadataCache
  )

  $jarPath = [string]$File.FullName
  $metadata = Get-McccCachedJarMetadata -JarPath $jarPath -Cache $MetadataCache -GetMetadata {
    param($cachedJarPath)
    try {
      return Get-McccJarMetadata -JarPath $cachedJarPath -ThrowOnParseError $false
    } catch {
      return $null
    }
  }

  $idSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $version = ""
  $loader = ""
  $hasMetadata = $false
  if ($null -ne $metadata) {
    $hasMetadata = $true
    if ($metadata.PSObject.Properties.Name -contains "Loader") {
      $loader = [string]$metadata.Loader
    }
    if ($metadata.PSObject.Properties.Name -contains "JarProvidedIds") {
      foreach ($item in @($metadata.JarProvidedIds)) {
        $value = [string]$item
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $null = $idSet.Add($value.Trim().ToLowerInvariant())
      }
    }
    if ($metadata.PSObject.Properties.Name -contains "Records") {
      foreach ($record in @($metadata.Records)) {
        if ($null -eq $record) { continue }
        $modId = if ($record.PSObject.Properties.Name -contains "ModId") { [string]$record.ModId } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($modId)) {
          $null = $idSet.Add($modId.Trim().ToLowerInvariant())
        }
        if ($record.PSObject.Properties.Name -contains "ProvidedIds") {
          foreach ($item in @($record.ProvidedIds)) {
            $value = [string]$item
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            $null = $idSet.Add($value.Trim().ToLowerInvariant())
          }
        }
        if ([string]::IsNullOrWhiteSpace($version) -and $record.PSObject.Properties.Name -contains "Version") {
          $version = [string]$record.Version
        }
      }
    }
  }

  return [pscustomobject]@{
    Name = [string]$File.Name
    Path = $jarPath
    LastWriteTime = [datetime]$File.LastWriteTime
    ModIds = @($idSet | Sort-Object)
    HasMetadata = [bool]$hasMetadata
    Loader = $loader
    Version = $version
  }
}

function Get-UpdateJarInfoList {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DirPath,
    [Parameter(Mandatory = $true)]
    [hashtable]$MetadataCache
  )

  if ([string]::IsNullOrWhiteSpace($DirPath) -or -not (Test-Path -LiteralPath $DirPath)) { return @() }
  $files = @(Get-McccJarFiles -RootPaths @($DirPath) -SortBy "LastWriteTime" -Descending $false -EnumerationErrorAction "SilentlyContinue")
  if ($files.Count -eq 0) { return @() }

  $result = New-Object System.Collections.Generic.List[object]
  foreach ($file in @($files)) {
    if ($null -eq $file) { continue }
    $result.Add((New-UpdateJarInfo -File $file -MetadataCache $metadataCache)) | Out-Null
  }

  if ($result.Count -eq 0) { return @() }
  return @($result.ToArray())
}

function Get-PathLowerSet {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$Paths = @()
  )

  $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($path in @($Paths)) {
    $value = [string]$path
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    $null = $set.Add($value.Trim().ToLowerInvariant())
  }
  return $set
}

function Get-OlderStorageMatches {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Candidate,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$StorageJarInfos = @(),
    [Parameter(Mandatory = $true)]
    [System.Collections.Generic.HashSet[string]]$ExcludedPathSet
  )

  if (-not $Candidate.ModIds -or $Candidate.ModIds.Count -eq 0) { return @() }
  $result = New-Object System.Collections.Generic.List[object]
  foreach ($item in @($StorageJarInfos)) {
    if ($null -eq $item) { continue }
    $path = [string]$item.Path
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    $pathKey = $path.ToLowerInvariant()
    if ($ExcludedPathSet.Contains($pathKey)) { continue }
    if ([string]::Equals($path, [string]$Candidate.Path, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    if ([datetime]$item.LastWriteTime -ge [datetime]$Candidate.LastWriteTime) { continue }
    if (-not (Test-ModIdOverlap -Left @($Candidate.ModIds) -Right @($item.ModIds))) { continue }
    $result.Add($item) | Out-Null
  }

  if ($result.Count -eq 0) { return @() }
  return @($result.ToArray() | Sort-Object -Property @{ Expression = { [datetime]$_.LastWriteTime }; Descending = $true }, @{ Expression = { [string]$_.Name }; Ascending = $true })
}

function Get-GameMatchesForReplacement {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Candidate,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$GameJarInfos = @()
  )

  if (-not $Candidate.ModIds -or $Candidate.ModIds.Count -eq 0) { return @() }
  $result = New-Object System.Collections.Generic.List[object]
  foreach ($item in @($GameJarInfos)) {
    if ($null -eq $item) { continue }
    if (-not (Test-ModIdOverlap -Left @($Candidate.ModIds) -Right @($item.ModIds))) { continue }
    if ([string]::Equals([string]$item.Name, [string]$Candidate.Name, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    $result.Add($item) | Out-Null
  }

  if ($result.Count -eq 0) { return @() }
  return @($result.ToArray() | Sort-Object -Property @{ Expression = { [datetime]$_.LastWriteTime }; Descending = $true }, @{ Expression = { [string]$_.Name }; Ascending = $true })
}

function Get-RollbackCandidateKey {
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarName
  )

  if ([string]::IsNullOrWhiteSpace($JarName)) { return "" }
  return $JarName.Trim().ToLowerInvariant()
}

function Add-RollbackCandidate {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$RollbackByJar,
    [Parameter(Mandatory = $true)]
    [string]$JarName,
    [Parameter(Mandatory = $true)]
    [string]$UpdatedPath,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$ModIds = @(),
    [Parameter(Mandatory = $false)]
    [datetime]$LastWriteTime = [datetime]::MinValue,
    [Parameter(Mandatory = $false)]
    [string]$Source = "storage"
  )

  $key = Get-RollbackCandidateKey -JarName $JarName
  if ([string]::IsNullOrWhiteSpace($key)) { return }
  if ([string]::IsNullOrWhiteSpace($UpdatedPath)) { return }

  $existing = $null
  if ($RollbackByJar.ContainsKey($key)) {
    $existing = $RollbackByJar[$key]
  }

  if ($null -ne $existing) {
    if (-not [string]::IsNullOrWhiteSpace([string]$existing.UpdatedPath) -and (Test-Path -LiteralPath ([string]$existing.UpdatedPath))) {
      return
    }
  }

  $RollbackByJar[$key] = [pscustomobject]@{
    JarName = [string]$JarName
    UpdatedPath = [string]$UpdatedPath
    ModIds = @($ModIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    LastWriteTime = [datetime]$LastWriteTime
    Source = [string]$Source
  }
}
function Test-LaunchProbeSuccess {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Probe
  )

  if ($null -eq $Probe -or $null -eq $Probe.Outcome) { return $false }
  $type = [string]$Probe.Outcome.Type
  return ($type -eq "Timeout" -or $type -eq "ProcessExit")
}

function Close-UpdateProbeOutcome {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Probe,
    [Parameter(Mandatory = $true)]
    [datetime]$SessionStartTime
  )

  if ($DryRun) { return }
  if ($null -eq $Probe -or $null -eq $Probe.Outcome) { return }

  $outcome = $Probe.Outcome
  if ($null -ne $outcome.Window) {
    [void](Close-OutcomeWindowWithExtraDialog -Outcome $outcome `
        -DelaySeconds $CrashCloseDelaySeconds `
        -OffsetX $CrashCloseClickOffsetX `
        -OffsetY $CrashCloseClickOffsetY `
        -CloseExtraFabricDialogs $true)
  }

  $closed = Stop-GameProcess -Names $GameProcessNames -StartedAfter $SessionStartTime
  if ($closed -gt 0) {
    Write-Host ("Closed {0} running game process(es)." -f $closed) -ForegroundColor Gray
  }

  [void](Wait-ForGameProcessesToExit -Names $GameProcessNames `
      -StartedAfter $SessionStartTime `
      -TimeoutSeconds $WaitForGameExitSeconds `
      -PollSeconds $GameExitPollSeconds)
}

function Get-UpdateLogSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [datetime]$SinceTimestamp
  )

  if ($DryRun) {
    return [pscustomobject]@{
      PrimaryLog = ""
      Logs = @()
      Lines = @()
      LineCount = 0
    }
  }

  return Get-ConfiguredLogSnapshot `
    -PrimaryLogPath $LogPath `
    -SinceTimestamp $SinceTimestamp `
    -SinceTimestampSkewSeconds 120
}

function Invoke-UpdateLaunchProbe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ContextLabel
  )

  if ($DryRun) {
    Write-Host ("DRYRUN: launch probe skipped for '{0}'." -f $ContextLabel) -ForegroundColor Gray
    return [pscustomobject]@{
      Context = $ContextLabel
      Outcome = [pscustomobject]@{ Type = "Timeout"; Window = $null }
      Snapshot = [pscustomobject]@{ PrimaryLog = ""; Logs = @(); Lines = @(); LineCount = 0 }
      DepInfo = [pscustomobject]@{ RequiringModIds = @(); MissingDepIds = @(); HasMissingDeps = $false }
      StartedAt = (Get-Date)
    }
  }

  Write-Host ("Launch probe: {0}" -f $ContextLabel) -ForegroundColor Cyan
  $startedAt = Get-Date
  $outcome = Invoke-LaunchAttempt -LauncherTitlePattern $LauncherWindowTitlePattern `
    -LauncherPath $LauncherExePath `
    -LauncherArgs $LauncherArguments `
    -AppendAutoLaunch ([bool]$effectiveAutoLaunch) `
    -LauncherTimeoutSeconds $LauncherWindowTimeoutSeconds `
    -ButtonNames $PlayButtonNames `
    -ClickOffsetX $PlayClickOffsetX `
    -ClickOffsetY $PlayClickOffsetY `
    -CrashPatterns $CrashWindowTitlePatterns `
    -FabricPatterns $FabricWindowTitlePatterns `
    -OutcomeTimeoutSeconds $OutcomeTimeoutSeconds `
    -PollSeconds $PollIntervalSeconds `
    -IgnoreHandleIds @()

  $snapshot = Get-UpdateLogSnapshot -SinceTimestamp $startedAt
  $depInfo = if ($null -ne $snapshot -and $snapshot.LineCount -gt 0) {
    Get-FabricDependencyDialogInfo -Lines $snapshot.Lines
  } else {
    [pscustomobject]@{ RequiringModIds = @(); MissingDepIds = @(); HasMissingDeps = $false }
  }

  $outcomeLabel = [string]$outcome.Type
  $outcomeColor = if ($outcomeLabel -eq "Timeout" -or $outcomeLabel -eq "ProcessExit") { "Green" } else { "Yellow" }
  Write-Host ("Outcome ({0}): {1}" -f $ContextLabel, $outcomeLabel) -ForegroundColor $outcomeColor

  return [pscustomobject]@{
    Context = $ContextLabel
    Outcome = $outcome
    Snapshot = $snapshot
    DepInfo = $depInfo
    StartedAt = $startedAt
  }
}

function Write-FabricMissingDependencyMessage {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$DepInfo
  )

  $missing = if ($DepInfo.MissingDepIds.Count -gt 0) { $DepInfo.MissingDepIds -join ", " } else { "<none>" }
  $requiring = if ($DepInfo.RequiringModIds.Count -gt 0) { $DepInfo.RequiringModIds -join ", " } else { "<none>" }
  Write-Host ("Fabric dialog shows missing dependencies: {0}." -f $missing) -ForegroundColor Yellow
  Write-Host ("Requiring mods: {0}" -f $requiring) -ForegroundColor Gray
}

function Test-UpdatePromptHasThreeChoices {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$PromptLines = @()
  )

  if (-not $PromptLines -or $PromptLines.Count -eq 0) { return $false }

  $hasYes = $false
  $hasNo = $false
  $hasCancel = $false
  foreach ($rawLine in @($PromptLines)) {
    $line = [string]$rawLine
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $trimmed = $line.Trim().ToLowerInvariant()
    if (-not $hasYes -and $trimmed -match "^(yes|да)\b") {
      $hasYes = $true
      continue
    }
    if (-not $hasNo -and $trimmed -match "^(no|нет)\b") {
      $hasNo = $true
      continue
    }
    if (-not $hasCancel -and $trimmed -match "^(cancel|отмена)\b") {
      $hasCancel = $true
      continue
    }
  }

  return ($hasYes -and $hasNo -and $hasCancel)
}

function Request-UpdateFallbackDecision {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [AllowEmptyString()]
    [string[]]$PromptLines,
    [Parameter(Mandatory = $false)]
    [string]$DialogTitle = "User action required"
  )

  $normalizedPromptLines = @($PromptLines | ForEach-Object { [string]$_ } | Where-Object { $null -ne $_ })
  $prompt = $normalizedPromptLines -join [Environment]::NewLine
  $localeTag = [string](Get-McccCurrentLocale)
  $isRuLocale = $false
  if (-not [string]::IsNullOrWhiteSpace($localeTag)) {
    $isRuLocale = $localeTag.Trim().ToLowerInvariant().StartsWith("ru")
  }

  $hasThreeWayPrompt = Test-UpdatePromptHasThreeChoices -PromptLines $normalizedPromptLines
  $dialogYesLabel = if ($isRuLocale) { "Да" } else { "Yes" }
  $dialogNoLabel = if ($isRuLocale) { "Нет" } else { "No" }
  $dialogEliminateLabel = if ($isRuLocale) { "Устранить" } else { "Eliminate" }
  $dialogCancelLabel = if ($isRuLocale) { "Отмена" } else { "Cancel" }
  $consoleFallbackPrompt = if ($isRuLocale) { "Запустить стандартный пайплайн? (y/n)" } else { "Run standard pipeline? (y/n)" }

  if ([string]::IsNullOrWhiteSpace($prompt)) {
    $prompt = @(
      "Launch preflight failed before update mode could start."
      ""
      "Eliminate - run standard pipeline."
      "Cancel - stop update mode."
    ) -join [Environment]::NewLine
  }

  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $DialogTitle
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(760, 300)

    $promptLabel = New-Object System.Windows.Forms.Label
    $promptLabel.AutoSize = $false
    $promptLabel.Left = 16
    $promptLabel.Top = 16
    $promptLabel.Width = 728
    $promptLabel.Height = 220
    $promptLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $promptLabel.Text = $prompt
    $form.Controls.Add($promptLabel)

    $primaryButton = New-Object System.Windows.Forms.Button
    $primaryButton.Width = 120
    $primaryButton.Height = 32
    $primaryButton.Top = 252
    $primaryButton.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Width = 120
    $cancelButton.Height = 32
    $cancelButton.Top = 252
    $cancelButton.Text = $dialogCancelLabel
    $cancelButton.Left = 624
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::No

    if ($hasThreeWayPrompt) {
      $primaryButton.Text = $dialogYesLabel
      $primaryButton.Left = 368

      $noButton = New-Object System.Windows.Forms.Button
      $noButton.Text = $dialogNoLabel
      $noButton.Width = 120
      $noButton.Height = 32
      $noButton.Left = 496
      $noButton.Top = 252
      $noButton.DialogResult = [System.Windows.Forms.DialogResult]::No
      $form.Controls.Add($noButton)

      $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    } else {
      $primaryButton.Text = $dialogEliminateLabel
      $primaryButton.Left = 496
    }

    $form.Controls.Add($primaryButton)
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $primaryButton
    $form.CancelButton = $cancelButton

    $result = $form.ShowDialog()
    $form.Dispose()
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
  } catch {
    Write-Host "Failed to open modal dialog. Falling back to console prompt." -ForegroundColor Yellow
    Write-Host $prompt -ForegroundColor Yellow
    $answer = [string](Read-Host $consoleFallbackPrompt)
    return ($answer.Trim().ToLowerInvariant() -in @("y", "yes"))
  }
}

function Stop-UpdateTranscript {
  if (-not [bool]$script:UpdateTranscriptStarted) { return }
  try {
    Stop-Transcript | Out-Null
  } catch {
    # * Keep fallback path resilient even if transcript shutdown fails.
  } finally {
    $script:UpdateTranscriptStarted = $false
  }
}

function Convert-StandardPipelineParameterValue {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object]$Value
  )

  if ($Value -is [System.Management.Automation.SwitchParameter]) {
    return [bool]$Value
  }
  return $Value
}

function Test-ShouldForwardStandardPipelineParameter {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object]$Value
  )

  if ($Value -is [System.Management.Automation.SwitchParameter]) {
    return [bool]$Value
  }
  if ($null -eq $Value) { return $false }

  switch ($Name) {
    "PlayClickOffsetX" { return ([int]$Value -ge 0) }
    "PlayClickOffsetY" { return ([int]$Value -ge 0) }
  }

  if ($Value -is [bool]) { return $true }
  if ($Value -is [int]) { return ([int]$Value -gt 0) }
  if ($Value -is [string]) { return (-not [string]::IsNullOrWhiteSpace([string]$Value)) }

  if ($Value -is [System.Array]) {
    return ($Value.Count -gt 0)
  }
  if ($Value -is [System.Collections.ICollection]) {
    return ($Value.Count -gt 0)
  }

  return $true
}

function Invoke-StandardPipeline {
  $standardScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Auto-Run-LegacyLauncher.ps1"
  if (-not (Test-Path -LiteralPath $standardScriptPath)) {
    throw ("Standard pipeline script not found: {0}" -f $standardScriptPath)
  }

  $updateCommand = Get-Command -Name $PSCommandPath -ErrorAction Stop
  $standardCommand = Get-Command -Name $standardScriptPath -ErrorAction Stop
  $params = @{}
  $excludedNames = @("UpdatePath", "RemainingArgs", "Help", "Verbose", "Debug")
  foreach ($name in @($updateCommand.Parameters.Keys)) {
    if ($excludedNames -contains [string]$name) { continue }
    if (-not $standardCommand.Parameters.ContainsKey([string]$name)) { continue }

    $valueVar = Get-Variable -Name ([string]$name) -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $valueVar) { continue }
    $value = $valueVar.Value
    if (-not (Test-ShouldForwardStandardPipelineParameter -Name ([string]$name) -Value $value)) { continue }

    $params[[string]$name] = Convert-StandardPipelineParameterValue -Value $value
  }

  $params["ContinueTranscript"] = $true
  if ($PSBoundParameters.ContainsKey("Verbose")) { $params["Verbose"] = $true }
  if ($PSBoundParameters.ContainsKey("Debug")) { $params["Debug"] = $true }

  if ($RemainingArgs -and $RemainingArgs.Count -gt 0) {
    & $standardScriptPath @params @RemainingArgs
  } else {
    & $standardScriptPath @params
  }

  return [int]$LASTEXITCODE
}

function Restore-RollbackCandidateToGame {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Candidate
  )

  $jarName = [string]$Candidate.JarName
  $sourcePath = [string]$Candidate.UpdatedPath
  if ([string]::IsNullOrWhiteSpace($jarName) -or [string]::IsNullOrWhiteSpace($sourcePath)) { return $false }

  $targetPath = Join-Path -Path $GameModsDir -ChildPath $jarName
  $copyResult = Copy-McccItem -LiteralPath $sourcePath -DestinationPath $targetPath -DryRun ([bool]$DryRun) -Overwrite $true -RetryCount 0 -RetryDelayMs 0
  if ($DryRun) {
    Write-Host ("DRYRUN add old version: {0}" -f $jarName) -ForegroundColor Gray
    return $true
  }

  if ($copyResult.Performed) {
    Write-Host ("Added old version to game mods: {0}" -f $jarName) -ForegroundColor Yellow
    return $true
  }

  return $false
}

function Deactivate-RollbackCandidateFromGame {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Candidate,
    [Parameter(Mandatory = $true)]
    [hashtable]$NewByJarName
  )

  $jarName = [string]$Candidate.JarName
  if ([string]::IsNullOrWhiteSpace($jarName)) { return $false }

  $targetPath = Join-Path -Path $GameModsDir -ChildPath $jarName
  $jarKey = $jarName.ToLowerInvariant()
  if ($NewByJarName.ContainsKey($jarKey)) {
    $newSourcePath = [string]$NewByJarName[$jarKey]
    if (-not [string]::IsNullOrWhiteSpace($newSourcePath) -and (Test-Path -LiteralPath $newSourcePath)) {
      $restoreNewResult = Copy-McccItem -LiteralPath $newSourcePath -DestinationPath $targetPath -DryRun ([bool]$DryRun) -Overwrite $true -RetryCount 0 -RetryDelayMs 0
      if ($DryRun) {
        Write-Host ("DRYRUN remove old version (restore new): {0}" -f $jarName) -ForegroundColor Gray
        return $true
      }
      return [bool]$restoreNewResult.Performed
    }
  }

  $removeResult = Remove-McccItem -LiteralPath $targetPath -DryRun ([bool]$DryRun) -Overwrite $true -RetryCount 0 -RetryDelayMs 0
  if ($DryRun) {
    Write-Host ("DRYRUN remove old version: {0}" -f $jarName) -ForegroundColor Gray
    return $true
  }

  return ([bool]$removeResult.Performed -or -not [bool]$removeResult.SourceExists)
}

function Select-TargetedRollbackCandidates {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Probe,
    [Parameter(Mandatory = $true)]
    [hashtable]$RollbackByJar,
    [Parameter(Mandatory = $true)]
    [hashtable]$ActiveRollbackByJar
  )

  $lines = @()
  if ($null -ne $Probe -and $null -ne $Probe.Snapshot -and $Probe.Snapshot.PSObject.Properties.Name -contains "Lines") {
    $lines = @($Probe.Snapshot.Lines)
  }

  $depInfo = if ($null -ne $Probe -and $null -ne $Probe.DepInfo) {
    $Probe.DepInfo
  } else {
    [pscustomobject]@{ RequiringModIds = @(); MissingDepIds = @(); HasMissingDeps = $false }
  }

  $incompatibleIds = @()
  if ($lines -and $lines.Count -gt 0) {
    $incompatibleIds = @(Get-IncompatibleModIdsFromLog -Lines $lines -IncludeWarnMixins $false)
    $incompatibleIds = @($incompatibleIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
  }

  $targetIdOrder = New-Object System.Collections.Generic.List[string]
  foreach ($id in @($depInfo.MissingDepIds + $depInfo.RequiringModIds + $incompatibleIds)) {
    $value = [string]$id
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    $targetIdOrder.Add($value.ToLowerInvariant()) | Out-Null
  }

  if ($targetIdOrder.Count -eq 0) { return @() }

  $selected = New-Object System.Collections.Generic.List[object]
  $selectedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($targetId in @($targetIdOrder.ToArray())) {
    foreach ($entry in @($RollbackByJar.Values)) {
      if ($null -eq $entry) { continue }
      $jarKey = Get-RollbackCandidateKey -JarName ([string]$entry.JarName)
      if ([string]::IsNullOrWhiteSpace($jarKey)) { continue }
      if ($ActiveRollbackByJar.ContainsKey($jarKey)) { continue }
      if ($selectedKeys.Contains($jarKey)) { continue }
      if (-not (Test-ModIdOverlap -Left @($entry.ModIds) -Right @($targetId))) { continue }
      $selected.Add($entry) | Out-Null
      $null = $selectedKeys.Add($jarKey)
    }
  }

  if ($selected.Count -eq 0) { return @() }
  return @($selected.ToArray() | Sort-Object -Property @{ Expression = { [datetime]$_.LastWriteTime }; Descending = $true }, @{ Expression = { [string]$_.JarName }; Ascending = $true })
}

function Get-UpdateCandidateBuckets {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$CandidateFiles = @(),
    [Parameter(Mandatory = $true)]
    [hashtable]$MetadataCache,
    [Parameter(Mandatory = $true)]
    [string]$StorageModsPath,
    [Parameter(Mandatory = $true)]
    [string]$GameModsPath,
    [Parameter(Mandatory = $true)]
    [System.Collections.Generic.HashSet[string]]$ExcludedPathSet
  )

  if (-not $CandidateFiles -or $CandidateFiles.Count -eq 0) {
    return [pscustomobject]@{
      Replaceable = @()
      NewOnly = @()
    }
  }

  $storageInfos = Get-UpdateJarInfoList -DirPath $StorageModsPath -MetadataCache $MetadataCache
  $gameInfos = Get-UpdateJarInfoList -DirPath $GameModsPath -MetadataCache $MetadataCache

  $replaceable = New-Object System.Collections.Generic.List[object]
  $newOnly = New-Object System.Collections.Generic.List[object]

  foreach ($candidateFile in @($CandidateFiles)) {
    if ($null -eq $candidateFile) { continue }
    if (-not (Test-Path -LiteralPath $candidateFile.FullName)) { continue }

    $candidateInfo = New-UpdateJarInfo -File $candidateFile -MetadataCache $MetadataCache
    $olderStorageMatches = @(Get-OlderStorageMatches -Candidate $candidateInfo -StorageJarInfos $storageInfos -ExcludedPathSet $ExcludedPathSet)
    $gameMatches = @(Get-GameMatchesForReplacement -Candidate $candidateInfo -GameJarInfos $gameInfos)

    if ($olderStorageMatches.Count -gt 0 -or $gameMatches.Count -gt 0) {
      $replaceable.Add($candidateFile) | Out-Null
    } else {
      $newOnly.Add($candidateFile) | Out-Null
    }
  }

  return [pscustomobject]@{
    Replaceable = @($replaceable.ToArray())
    NewOnly = @($newOnly.ToArray())
  }
}

function Invoke-UpdateReplacementBatch {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$CandidateFiles = @(),
    [Parameter(Mandatory = $true)]
    [hashtable]$MetadataCache,
    [Parameter(Mandatory = $true)]
    [string]$ResolvedStorageModsDir,
    [Parameter(Mandatory = $true)]
    [string]$ResolvedGameModsDir,
    [Parameter(Mandatory = $true)]
    [System.Collections.Generic.HashSet[string]]$UpdatePathSet,
    [Parameter(Mandatory = $true)]
    [string]$SessionUpdatedDir,
    [Parameter(Mandatory = $true)]
    [hashtable]$RollbackByJar
  )

  $movedStorageOldCount = 0
  $removedGameOldCount = 0
  $copiedNewCount = 0

  foreach ($candidateFile in @($CandidateFiles)) {
    if ($null -eq $candidateFile) { continue }
    if (-not (Test-Path -LiteralPath $candidateFile.FullName)) {
      Write-Host ("Skipping missing update candidate: {0}" -f $candidateFile.FullName) -ForegroundColor Yellow
      continue
    }

    $candidateInfo = New-UpdateJarInfo -File $candidateFile -MetadataCache $MetadataCache
    Write-Host ("Processing update candidate: {0}" -f $candidateInfo.Name) -ForegroundColor Cyan

    if (-not $candidateInfo.HasMetadata) {
      Write-Host ("Warning: metadata parse failed for {0}. Old-version matching may be incomplete." -f $candidateInfo.Name) -ForegroundColor Yellow
    }

    $storageInfosNow = Get-UpdateJarInfoList -DirPath $ResolvedStorageModsDir -MetadataCache $MetadataCache
    $gameInfosNow = Get-UpdateJarInfoList -DirPath $ResolvedGameModsDir -MetadataCache $MetadataCache

    $olderStorageMatches = @(Get-OlderStorageMatches -Candidate $candidateInfo -StorageJarInfos $storageInfosNow -ExcludedPathSet $UpdatePathSet)
    foreach ($oldStorage in @($olderStorageMatches)) {
      $destPath = Join-McccDestinationPath -SourcePath ([string]$oldStorage.Path) -DestinationDirectory $SessionUpdatedDir
      $moveResult = Move-McccItem -LiteralPath ([string]$oldStorage.Path) -DestinationPath $destPath -DryRun ([bool]$DryRun) -Overwrite $true -RetryCount 0 -RetryDelayMs 0
      if ($DryRun) {
        Write-Host ("DRYRUN move old storage version to Updated: {0}" -f $oldStorage.Name) -ForegroundColor Gray
        Add-RollbackCandidate -RollbackByJar $RollbackByJar -JarName ([string]$oldStorage.Name) -UpdatedPath $destPath -ModIds @($oldStorage.ModIds) -LastWriteTime ([datetime]$oldStorage.LastWriteTime)
        continue
      }

      if ($moveResult.Performed) {
        Write-Host ("Moved old storage version to Updated: {0}" -f $oldStorage.Name) -ForegroundColor Gray
        Add-RollbackCandidate -RollbackByJar $RollbackByJar -JarName ([string]$oldStorage.Name) -UpdatedPath $destPath -ModIds @($oldStorage.ModIds) -LastWriteTime ([datetime]$oldStorage.LastWriteTime)
        $movedStorageOldCount++
      }
    }

    $gameMatches = @(Get-GameMatchesForReplacement -Candidate $candidateInfo -GameJarInfos $gameInfosNow)
    foreach ($oldGame in @($gameMatches)) {
      if (-not $RollbackByJar.ContainsKey(([string]$oldGame.Name).ToLowerInvariant())) {
        $backupPath = Join-McccDestinationPath -SourcePath ([string]$oldGame.Path) -DestinationDirectory $SessionUpdatedDir
        $backupResult = Copy-McccItem -LiteralPath ([string]$oldGame.Path) -DestinationPath $backupPath -DryRun ([bool]$DryRun) -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        if ($DryRun) {
          Add-RollbackCandidate -RollbackByJar $RollbackByJar -JarName ([string]$oldGame.Name) -UpdatedPath $backupPath -ModIds @($oldGame.ModIds) -LastWriteTime ([datetime]$oldGame.LastWriteTime) -Source "game"
        } elseif ($backupResult.Performed) {
          Add-RollbackCandidate -RollbackByJar $RollbackByJar -JarName ([string]$oldGame.Name) -UpdatedPath $backupPath -ModIds @($oldGame.ModIds) -LastWriteTime ([datetime]$oldGame.LastWriteTime) -Source "game"
        }
      }

      $removeResult = Remove-McccItem -LiteralPath ([string]$oldGame.Path) -DryRun ([bool]$DryRun) -Overwrite $true -RetryCount 0 -RetryDelayMs 0
      if ($DryRun) {
        Write-Host ("DRYRUN remove old game version: {0}" -f $oldGame.Name) -ForegroundColor Gray
        continue
      }

      if ($removeResult.Performed) {
        Write-Host ("Removed old game version: {0}" -f $oldGame.Name) -ForegroundColor Gray
        $removedGameOldCount++
      }
    }

    $gameTargetPath = Join-Path -Path $ResolvedGameModsDir -ChildPath $candidateInfo.Name
    $copyNewResult = Copy-McccItem -LiteralPath ([string]$candidateInfo.Path) -DestinationPath $gameTargetPath -DryRun ([bool]$DryRun) -Overwrite $true -RetryCount 0 -RetryDelayMs 0
    if ($DryRun) {
      Write-Host ("DRYRUN copy new version to game mods: {0}" -f $candidateInfo.Name) -ForegroundColor Gray
    } elseif ($copyNewResult.Performed) {
      Write-Host ("Applied new version to game mods: {0}" -f $candidateInfo.Name) -ForegroundColor Green
      $copiedNewCount++
    }
  }

  return [pscustomobject]@{
    CopiedNewCount = [int]$copiedNewCount
    MovedStorageOldCount = [int]$movedStorageOldCount
    RemovedGameOldCount = [int]$removedGameOldCount
  }
}

function Invoke-UpdateNewOnlyBatch {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$CandidateFiles = @(),
    [Parameter(Mandatory = $true)]
    [hashtable]$MetadataCache,
    [Parameter(Mandatory = $true)]
    [string]$ResolvedGameModsDir
  )

  $copiedNewCount = 0
  foreach ($candidateFile in @($CandidateFiles)) {
    if ($null -eq $candidateFile) { continue }
    if (-not (Test-Path -LiteralPath $candidateFile.FullName)) {
      Write-Host ("Skipping missing update candidate: {0}" -f $candidateFile.FullName) -ForegroundColor Yellow
      continue
    }

    $candidateInfo = New-UpdateJarInfo -File $candidateFile -MetadataCache $MetadataCache
    Write-Host ("Processing new-only candidate: {0}" -f $candidateInfo.Name) -ForegroundColor Cyan

    if (-not $candidateInfo.HasMetadata) {
      Write-Host ("Warning: metadata parse failed for {0}. New-only classification may be incomplete." -f $candidateInfo.Name) -ForegroundColor Yellow
    }

    $gameTargetPath = Join-Path -Path $ResolvedGameModsDir -ChildPath $candidateInfo.Name
    $copyNewResult = Copy-McccItem -LiteralPath ([string]$candidateInfo.Path) -DestinationPath $gameTargetPath -DryRun ([bool]$DryRun) -Overwrite $true -RetryCount 0 -RetryDelayMs 0
    if ($DryRun) {
      Write-Host ("DRYRUN copy new-only mod to game mods: {0}" -f $candidateInfo.Name) -ForegroundColor Gray
      continue
    }

    if ($copyNewResult.Performed) {
      Write-Host ("Applied new-only mod to game mods: {0}" -f $candidateInfo.Name) -ForegroundColor Green
      $copiedNewCount++
    }
  }

  return [pscustomobject]@{
    CopiedNewCount = [int]$copiedNewCount
  }
}

$projectRoot = [string]$runtimeBootstrap.ProjectRoot
$script:UpdateTranscriptPath = Join-Path -Path $projectRoot -ChildPath "MCCC.log"
$script:UpdateTranscriptStarted = $false

try {
  if (Test-Path -LiteralPath $script:UpdateTranscriptPath) {
    Remove-Item -LiteralPath $script:UpdateTranscriptPath -Force -ErrorAction Stop
  }
  Start-Transcript -Path $script:UpdateTranscriptPath -Force | Out-Null
  $script:UpdateTranscriptStarted = $true

$effectiveAutoLaunch = ([bool]$UseAutoLaunch) -and (-not [bool]$DisableAutoLaunch)
$sessionStartTime = Get-Date
$updateBatchMcVersion = "unknown"

if ([string]::IsNullOrWhiteSpace($StorageModsDir)) {
  throw "StorageModsDir is not configured. Update mode requires a storage directory."
}
if (-not (Test-Path -LiteralPath $StorageModsDir)) {
  throw ("StorageModsDir not found: {0}" -f $StorageModsDir)
}
if (-not (Test-Path -LiteralPath $GameModsDir)) {
  throw ("GameModsDir not found: {0}" -f $GameModsDir)
}

$resolvedGameModsDir = (Resolve-Path -LiteralPath $GameModsDir).Path
$resolvedStorageModsDir = (Resolve-Path -LiteralPath $StorageModsDir).Path
if ([string]::Equals($resolvedGameModsDir, $resolvedStorageModsDir, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Update mode requires StorageModsDir to be different from GameModsDir."
}

if ([string]::IsNullOrWhiteSpace($UpdatePath)) {
  throw "UpdatePath is required."
}
if (-not (Test-Path -LiteralPath $UpdatePath)) {
  throw ("Update anchor file not found: {0}" -f $UpdatePath)
}

$resolvedUpdatePath = (Resolve-Path -LiteralPath $UpdatePath).Path
$updateFile = Get-Item -LiteralPath $resolvedUpdatePath -ErrorAction Stop
if ($updateFile.PSIsContainer) {
  throw ("UpdatePath must point to a .jar file, got directory: {0}" -f $resolvedUpdatePath)
}
if (-not [string]::Equals([string]$updateFile.Extension, ".jar", [System.StringComparison]::OrdinalIgnoreCase)) {
  throw ("UpdatePath must point to a .jar file: {0}" -f $resolvedUpdatePath)
}

$anchorParent = (Split-Path -Path $resolvedUpdatePath -Parent)
if (-not [string]::Equals($anchorParent, $resolvedStorageModsDir, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw ("UpdatePath must be a direct file in StorageModsDir root: {0}" -f $resolvedStorageModsDir)
}

Write-UpdateStage -Name "Initialization"
Write-Host ("Update mode: anchor jar = {0}" -f $resolvedUpdatePath) -ForegroundColor Cyan
Write-Host ("Update mode: storage root = {0}" -f $resolvedStorageModsDir) -ForegroundColor Gray
Write-Host ("Update mode: game mods = {0}" -f $resolvedGameModsDir) -ForegroundColor Gray

$metadataCache = @{}
$storageRootFiles = @(Get-McccJarFiles -RootPaths @($resolvedStorageModsDir) -SortBy "LastWriteTime" -Descending $false -EnumerationErrorAction "Stop")
if ($storageRootFiles.Count -eq 0) {
  Write-Host "No jar files found in StorageModsDir root." -ForegroundColor Yellow
  exit 0
}

$anchorTime = [datetime]$updateFile.LastWriteTime
$updateCandidates = @($storageRootFiles | Where-Object { [datetime]$_.LastWriteTime -ge $anchorTime })
if (-not $updateCandidates -or $updateCandidates.Count -eq 0) {
  Write-Host "No update candidates found at/after anchor timestamp." -ForegroundColor Yellow
  exit 0
}

$anchorIncluded = $false
foreach ($item in @($updateCandidates)) {
  if ($null -eq $item) { continue }
  if ([string]::Equals([string]$item.FullName, $resolvedUpdatePath, [System.StringComparison]::OrdinalIgnoreCase)) {
    $anchorIncluded = $true
    break
  }
}
if (-not $anchorIncluded) {
  $updateCandidates = @($updateCandidates + @($updateFile))
}

$updateCandidates = @($updateCandidates | Sort-Object -Property @{ Expression = { [datetime]$_.LastWriteTime }; Ascending = $true }, @{ Expression = { [string]$_.Name }; Ascending = $true }, @{ Expression = { [string]$_.FullName }; Ascending = $true })

$updatePathSet = Get-PathLowerSet -Paths @($updateCandidates | ForEach-Object { [string]$_.FullName })
$newCandidateByJarName = @{}
foreach ($item in @($updateCandidates)) {
  if ($null -eq $item) { continue }
  $name = [string]$item.Name
  $path = [string]$item.FullName
  if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($path)) { continue }
  $newCandidateByJarName[$name.ToLowerInvariant()] = $path
}

Write-Host ("Update candidate count (anchor included): {0}" -f $updateCandidates.Count) -ForegroundColor Cyan

Write-UpdateStage -Name "Candidate classification"
$candidateBuckets = Get-UpdateCandidateBuckets `
  -CandidateFiles $updateCandidates `
  -MetadataCache $metadataCache `
  -StorageModsPath $resolvedStorageModsDir `
  -GameModsPath $resolvedGameModsDir `
  -ExcludedPathSet $updatePathSet
$replaceableCandidates = @($candidateBuckets.Replaceable)
$newOnlyCandidates = @($candidateBuckets.NewOnly)

Write-Host ("Update candidate groups: replaceable={0}, new-only={1}" -f $replaceableCandidates.Count, $newOnlyCandidates.Count) -ForegroundColor Cyan
if ($replaceableCandidates.Count -gt 0) {
  $replaceableNames = @($replaceableCandidates | ForEach-Object { [string]$_.Name }) -join ", "
  Write-Host ("Replaceable candidates: {0}" -f $replaceableNames) -ForegroundColor Gray
}
if ($newOnlyCandidates.Count -gt 0) {
  $newOnlyNames = @($newOnlyCandidates | ForEach-Object { [string]$_.Name }) -join ", "
  Write-Host ("New-only candidates: {0}" -f $newOnlyNames) -ForegroundColor Gray
}

if ($DryRun) {
  Write-Host "DRYRUN enabled. Preflight and file changes will be simulated." -ForegroundColor Gray
} else {
  if ($PlayClickOffsetX -lt 0 -or $PlayClickOffsetY -lt 0) {
    $offsetResult = Resolve-LauncherPlayClickOffset -LauncherTitlePattern $LauncherWindowTitlePattern `
      -LauncherExePath $LauncherExePath `
      -LauncherArguments $LauncherArguments `
      -AppendAutoLaunch $effectiveAutoLaunch `
      -LauncherWindowTimeoutSeconds $LauncherWindowTimeoutSeconds `
      -PollIntervalSeconds $PollIntervalSeconds `
      -CurrentPlayClickOffsetX $PlayClickOffsetX `
      -CurrentPlayClickOffsetY $PlayClickOffsetY `
      -PrintProvidedOffsetMessage $false `
      -IsDryRun ([bool]$DryRun)
    $PlayClickOffsetX = [int]$offsetResult.PlayClickOffsetX
    $PlayClickOffsetY = [int]$offsetResult.PlayClickOffsetY
  }

  Write-UpdateStage -Name "Preflight launch check"
  $preflightProbe = Invoke-UpdateLaunchProbe -ContextLabel "preflight"
  if ($null -ne $preflightProbe -and $null -ne $preflightProbe.Snapshot -and $preflightProbe.Snapshot.PSObject.Properties.Name -contains "Lines") {
    $preflightLines = @($preflightProbe.Snapshot.Lines)
    if ($preflightLines.Count -gt 0) {
      $detectedMcVersion = [string](Get-MinecraftVersionFromLog -Lines $preflightLines)
      if (-not [string]::IsNullOrWhiteSpace($detectedMcVersion)) {
        $updateBatchMcVersion = $detectedMcVersion
      }
    }
  }

  $preflightOutcomeType = [string]$preflightProbe.Outcome.Type

  if ($preflightOutcomeType -eq "FabricDialog" -and $null -ne $preflightProbe.DepInfo -and [bool]$preflightProbe.DepInfo.HasMissingDeps) {
    Write-FabricMissingDependencyMessage -DepInfo $preflightProbe.DepInfo
    $preflightPrompt = @(
      "Preflight detected missing dependencies."
      ""
      "Run standard compatibility pipeline instead?"
      "Eliminate - run standard pipeline."
      "Cancel - stop update mode."
    )
    $runStandard = Request-UpdateFallbackDecision -PromptLines $preflightPrompt -DialogTitle "Preflight missing dependencies"
    Close-UpdateProbeOutcome -Probe $preflightProbe -SessionStartTime $sessionStartTime
    if ($runStandard) {
      Write-Host "Switching to standard compatibility pipeline." -ForegroundColor Cyan
      $standardExitCode = Invoke-StandardPipeline
      exit $standardExitCode
    }

    Write-Host "Update mode canceled by user after preflight missing dependencies." -ForegroundColor Yellow
    exit 0
  }

  if ($preflightOutcomeType -eq "CrashDialog" -or $preflightOutcomeType -eq "NoLaunch") {
    $preflightPrompt = @(
      ("Preflight outcome: {0}." -f $preflightOutcomeType)
      ""
      "Run standard compatibility pipeline instead?"
      "Eliminate - run standard pipeline."
      "Cancel - stop update mode."
    )
    $runStandard = Request-UpdateFallbackDecision -PromptLines $preflightPrompt -DialogTitle "Preflight failed"
    Close-UpdateProbeOutcome -Probe $preflightProbe -SessionStartTime $sessionStartTime
    if ($runStandard) {
      Write-Host "Switching to standard compatibility pipeline." -ForegroundColor Cyan
      $standardExitCode = Invoke-StandardPipeline
      exit $standardExitCode
    }

    Write-Host "Update mode canceled by user after preflight failure." -ForegroundColor Yellow
    exit 0
  }

  if ($preflightOutcomeType -eq "FabricDialog" -and ($null -eq $preflightProbe.DepInfo -or (-not [bool]$preflightProbe.DepInfo.HasMissingDeps))) {
    Write-Host "Preflight detected Fabric dialog without missing dependency signal." -ForegroundColor Yellow
    $preflightPrompt = @(
      "Preflight launch did not pass cleanly."
      ""
      "Run standard compatibility pipeline instead?"
      "Eliminate - run standard pipeline."
      "Cancel - stop update mode."
    )
    $runStandard = Request-UpdateFallbackDecision -PromptLines $preflightPrompt -DialogTitle "Preflight requires action"
    Close-UpdateProbeOutcome -Probe $preflightProbe -SessionStartTime $sessionStartTime
    if ($runStandard) {
      Write-Host "Switching to standard compatibility pipeline." -ForegroundColor Cyan
      $standardExitCode = Invoke-StandardPipeline
      exit $standardExitCode
    }

    Write-Host "Update mode canceled by user after preflight warning." -ForegroundColor Yellow
    exit 0
  }

  Close-UpdateProbeOutcome -Probe $preflightProbe -SessionStartTime $sessionStartTime
}

$updatedFolderName = Resolve-McccFolderName -Role "Updated"
$sessionUpdatedRoot = Join-Path -Path $resolvedStorageModsDir -ChildPath $updatedFolderName
$updatedVersionFolder = [string]$updateBatchMcVersion
if ([string]::IsNullOrWhiteSpace($updatedVersionFolder)) { $updatedVersionFolder = "unknown" }
$sessionUpdatedDir = Join-Path -Path $sessionUpdatedRoot -ChildPath $updatedVersionFolder

$rollbackByJar = @{}
$activeRollbackByJar = @{}
if ($replaceableCandidates.Count -gt 0) {
  Write-UpdateStage -Name "Apply replaceable batch"
  $replaceBatchResult = Invoke-UpdateReplacementBatch `
    -CandidateFiles $replaceableCandidates `
    -MetadataCache $metadataCache `
    -ResolvedStorageModsDir $resolvedStorageModsDir `
    -ResolvedGameModsDir $resolvedGameModsDir `
    -UpdatePathSet $updatePathSet `
    -SessionUpdatedDir $sessionUpdatedDir `
    -RollbackByJar $rollbackByJar
  Write-Host ("Replaceable batch summary: new={0}, moved-old-storage={1}, removed-old-game={2}" -f $replaceBatchResult.CopiedNewCount, $replaceBatchResult.MovedStorageOldCount, $replaceBatchResult.RemovedGameOldCount) -ForegroundColor Cyan

  if (-not $DryRun) {
    Write-UpdateStage -Name "Post-replaceable launch check"
    $postProbe = Invoke-UpdateLaunchProbe -ContextLabel "post-replaceable"
    Close-UpdateProbeOutcome -Probe $postProbe -SessionStartTime $sessionStartTime

    if (-not (Test-LaunchProbeSuccess -Probe $postProbe)) {
      if ($postProbe.Outcome.Type -eq "FabricDialog" -and $null -ne $postProbe.DepInfo -and [bool]$postProbe.DepInfo.HasMissingDeps) {
        Write-FabricMissingDependencyMessage -DepInfo $postProbe.DepInfo
      }

      Write-UpdateStage -Name "Targeted rollback restore"
      $targetedRestores = 0
      $targetedMaxRounds = 8
      $currentProbe = $postProbe
      for ($round = 1; $round -le $targetedMaxRounds; $round++) {
        $targetedCandidates = @(Select-TargetedRollbackCandidates -Probe $currentProbe -RollbackByJar $rollbackByJar -ActiveRollbackByJar $activeRollbackByJar)
        if ($targetedCandidates.Count -eq 0) {
          Write-Host "No targeted rollback candidates found for current logs." -ForegroundColor Gray
          break
        }

        Write-Host ("Targeted rollback round {0}: {1} candidate(s)." -f $round, $targetedCandidates.Count) -ForegroundColor Cyan
        $restoredThisRound = 0
        foreach ($candidate in @($targetedCandidates)) {
          if ($null -eq $candidate) { continue }
          $jarKey = Get-RollbackCandidateKey -JarName ([string]$candidate.JarName)
          if ([string]::IsNullOrWhiteSpace($jarKey)) { continue }
          if ($activeRollbackByJar.ContainsKey($jarKey)) { continue }

          if (Restore-RollbackCandidateToGame -Candidate $candidate) {
            $activeRollbackByJar[$jarKey] = $candidate
            $restoredThisRound++
            $targetedRestores++
          }
        }

        if ($restoredThisRound -le 0) {
          break
        }

        $currentProbe = Invoke-UpdateLaunchProbe -ContextLabel ("targeted-rollback-{0}" -f $round)
        Close-UpdateProbeOutcome -Probe $currentProbe -SessionStartTime $sessionStartTime
        if (Test-LaunchProbeSuccess -Probe $currentProbe) {
          Write-Host "Targeted rollback restored launch stability." -ForegroundColor Green
          break
        }

        if ($currentProbe.Outcome.Type -eq "FabricDialog" -and $null -ne $currentProbe.DepInfo -and [bool]$currentProbe.DepInfo.HasMissingDeps) {
          Write-FabricMissingDependencyMessage -DepInfo $currentProbe.DepInfo
        }
      }

      if (-not (Test-LaunchProbeSuccess -Probe $currentProbe)) {
        Write-UpdateStage -Name "Additive rollback layering"
        $remainingCandidates = @($rollbackByJar.Values | Where-Object {
            $entry = $_
            if ($null -eq $entry) { return $false }
            $key = Get-RollbackCandidateKey -JarName ([string]$entry.JarName)
            return (-not [string]::IsNullOrWhiteSpace($key) -and (-not $activeRollbackByJar.ContainsKey($key)))
          } | Sort-Object -Property @{ Expression = { [datetime]$_.LastWriteTime }; Descending = $true }, @{ Expression = { [string]$_.JarName }; Ascending = $true })

        if ($remainingCandidates.Count -eq 0) {
          Write-Host "No remaining rollback candidates for additive layering." -ForegroundColor Gray
        } else {
          $index = 0
          $batchSize = 1
          $layerRound = 0
          while ($index -lt $remainingCandidates.Count -and (-not (Test-LaunchProbeSuccess -Probe $currentProbe))) {
            $layerRound++
            $takeCount = [Math]::Min($batchSize, ($remainingCandidates.Count - $index))
            $batch = @($remainingCandidates[$index..($index + $takeCount - 1)])
            $batchLabel = @($batch | ForEach-Object { [string]$_.JarName }) -join ", "
            Write-Host ("Layering round {0}: add {1}" -f $layerRound, $batchLabel) -ForegroundColor Cyan

            foreach ($candidate in @($batch)) {
              if ($null -eq $candidate) { continue }
              $jarKey = Get-RollbackCandidateKey -JarName ([string]$candidate.JarName)
              if ([string]::IsNullOrWhiteSpace($jarKey)) { continue }
              if ($activeRollbackByJar.ContainsKey($jarKey)) { continue }
              if (Restore-RollbackCandidateToGame -Candidate $candidate) {
                $activeRollbackByJar[$jarKey] = $candidate
              }
            }

            $currentProbe = Invoke-UpdateLaunchProbe -ContextLabel ("layering-rollback-{0}" -f $layerRound)
            Close-UpdateProbeOutcome -Probe $currentProbe -SessionStartTime $sessionStartTime
            if (Test-LaunchProbeSuccess -Probe $currentProbe) {
              Write-Host "Additive rollback layering restored launch stability." -ForegroundColor Green
              break
            }

            if ($currentProbe.Outcome.Type -eq "FabricDialog" -and $null -ne $currentProbe.DepInfo -and [bool]$currentProbe.DepInfo.HasMissingDeps) {
              Write-FabricMissingDependencyMessage -DepInfo $currentProbe.DepInfo
            }

            $index += $takeCount
            $batchSize = [Math]::Min(($batchSize * 2), ($remainingCandidates.Count - $index))
            if ($batchSize -lt 1) { $batchSize = 1 }
          }
        }
      }

      if (-not (Test-LaunchProbeSuccess -Probe $currentProbe)) {
        Write-Host "Replaceable batch is still unstable even after rollback layering." -ForegroundColor Red
        $replaceablePrompt = @(
          ("Post-replaceable outcome: {0}." -f [string]$currentProbe.Outcome.Type)
          ""
          "Run standard compatibility pipeline instead?"
          "Eliminate - run standard pipeline."
          "Cancel - stop update mode."
        )
        $runStandard = Request-UpdateFallbackDecision -PromptLines $replaceablePrompt -DialogTitle "Replaceable batch failed"
        if ($runStandard) {
          Write-Host "Switching to standard compatibility pipeline." -ForegroundColor Cyan
          $standardExitCode = Invoke-StandardPipeline
          exit $standardExitCode
        }

        Write-Host "Update mode canceled by user after replaceable batch failure." -ForegroundColor Yellow
        exit 3
      }
    }

    if ($activeRollbackByJar.Count -gt 0) {
      Write-UpdateStage -Name "Rollback minimization"
      $activeOrdered = @($activeRollbackByJar.Values | Sort-Object -Property @{ Expression = { [datetime]$_.LastWriteTime }; Descending = $true }, @{ Expression = { [string]$_.JarName }; Ascending = $true })
      foreach ($candidate in @($activeOrdered)) {
        if ($null -eq $candidate) { continue }
        $jarName = [string]$candidate.JarName
        $jarKey = Get-RollbackCandidateKey -JarName $jarName
        if ([string]::IsNullOrWhiteSpace($jarKey)) { continue }
        if (-not $activeRollbackByJar.ContainsKey($jarKey)) { continue }

        Write-Host ("Minimize: remove old version candidate '{0}' and re-test." -f $jarName) -ForegroundColor Cyan
        if (-not (Deactivate-RollbackCandidateFromGame -Candidate $candidate -NewByJarName $newCandidateByJarName)) {
          Write-Host ("Warning: failed to temporarily deactivate old version '{0}'." -f $jarName) -ForegroundColor Yellow
          continue
        }

        $minProbe = Invoke-UpdateLaunchProbe -ContextLabel ("minimize-remove-{0}" -f $jarName)
        Close-UpdateProbeOutcome -Probe $minProbe -SessionStartTime $sessionStartTime
        if (Test-LaunchProbeSuccess -Probe $minProbe) {
          $null = $activeRollbackByJar.Remove($jarKey)
          Write-Host ("Old version '{0}' is not required." -f $jarName) -ForegroundColor Green
          continue
        }

        if (Restore-RollbackCandidateToGame -Candidate $candidate) {
          Write-Host ("Old version '{0}' is still required." -f $jarName) -ForegroundColor Yellow
          $activeRollbackByJar[$jarKey] = $candidate
        } else {
          Write-Host ("Warning: failed to restore required old version '{0}'." -f $jarName) -ForegroundColor Red
        }
      }
    }
  }
} else {
  Write-Host "No replaceable update candidates were found." -ForegroundColor Gray
}

if ($newOnlyCandidates.Count -gt 0) {
  Write-UpdateStage -Name "Apply new-only batch"
  $newOnlyResult = Invoke-UpdateNewOnlyBatch `
    -CandidateFiles $newOnlyCandidates `
    -MetadataCache $metadataCache `
    -ResolvedGameModsDir $resolvedGameModsDir
  Write-Host ("New-only batch summary: new={0}" -f $newOnlyResult.CopiedNewCount) -ForegroundColor Cyan

  if ($DryRun) {
    Write-Host "DRYRUN complete." -ForegroundColor Green
    exit 0
  }

  Write-UpdateStage -Name "Post new-only launch check"
  $newOnlyProbe = Invoke-UpdateLaunchProbe -ContextLabel "post-new-only"
  Close-UpdateProbeOutcome -Probe $newOnlyProbe -SessionStartTime $sessionStartTime
  if (-not (Test-LaunchProbeSuccess -Probe $newOnlyProbe)) {
    if ($newOnlyProbe.Outcome.Type -eq "FabricDialog" -and $null -ne $newOnlyProbe.DepInfo -and [bool]$newOnlyProbe.DepInfo.HasMissingDeps) {
      Write-FabricMissingDependencyMessage -DepInfo $newOnlyProbe.DepInfo
    }

    $newOnlyPrompt = @(
      ("Post new-only outcome: {0}." -f [string]$newOnlyProbe.Outcome.Type)
      ""
      "Run standard compatibility pipeline instead?"
      "Eliminate - run standard pipeline."
      "Cancel - stop update mode."
    )
    $runStandard = Request-UpdateFallbackDecision -PromptLines $newOnlyPrompt -DialogTitle "New-only batch requires action"
    if ($runStandard) {
      Write-Host "Switching to standard compatibility pipeline." -ForegroundColor Cyan
      $standardExitCode = Invoke-StandardPipeline
      exit $standardExitCode
    }

    Write-Host "Update mode canceled by user after new-only batch issue." -ForegroundColor Yellow
    exit 0
  }

  if ($activeRollbackByJar.Count -gt 0) {
    Write-UpdateStage -Name "Final compatibility check"
    Write-Host "Switching to standard compatibility pipeline for final validation of new-only mods." -ForegroundColor Cyan
    $standardExitCode = Invoke-StandardPipeline
    exit $standardExitCode
  }
}

if ($DryRun) {
  Write-Host "DRYRUN complete." -ForegroundColor Green
  exit 0
}

if ($activeRollbackByJar.Count -gt 0) {
  $requiredOld = @($activeRollbackByJar.Values | ForEach-Object { [string]$_.JarName } | Sort-Object -Unique)
  Write-Host ("Update mode completed with required old versions: {0}" -f ($requiredOld -join ", ")) -ForegroundColor Yellow
} else {
  Write-Host "Update mode completed without old-version fallback requirements." -ForegroundColor Green
}

exit 0
} finally {
  Stop-UpdateTranscript
}
