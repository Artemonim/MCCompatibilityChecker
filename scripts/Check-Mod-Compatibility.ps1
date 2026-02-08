<#
.SYNOPSIS
Detects incompatible Minecraft mods from Fabric/TLauncher logs.

.DESCRIPTION
Reads the latest tl-logger*.txt or a specified log file and can also scan recent game logs
(latest.log/debug.log and the newest crash report) to extract mod IDs from Fabric/Mixin errors,
and removes the offending jars from the game mods folder. By default, removed mods are moved into
a legacy folder inside the storage directory. Use -GameLegacy to also keep a legacy copy inside
the game mods folder. Use -NoLegacy to delete removed mods instead of moving them to legacy.
Compatibility logs (legacy.log and compat-report-*.json) are written only when -Verbose is used.

.PARAMETER LogPath
Path to tl-logger*.txt or a Fabric log file. Leave empty to auto-pick the latest temp log.

.PARAMETER GameModsDir
Active mods folder used by the launcher/game.

.PARAMETER StorageModsDir
Main mods storage (the "source of truth").

.PARAMETER StorageLegacyFolderName
Subfolder name inside StorageModsDir where legacy jars are placed.

.PARAMETER GameLegacyFolderName
Subfolder name inside GameModsDir where removed jars are placed when -GameLegacy is used.

.PARAMETER NoLegacy
If set, does not keep legacy copies. Removed mods are deleted from game and storage.

.PARAMETER GameLegacy
If set, also keeps legacy copies inside the game mods folder. Without this flag, the game mods
copy is deleted and only the storage legacy is kept (unless -NoLegacy is used).

.PARAMETER DeleteFromGameMods
If set, deletes from GameModsDir instead of moving to GameLegacyFolderName.

.PARAMETER TreatNonFabricAsIncompatible
If set, treats "Found N non-fabric mods" list as incompatible (moves/deletes by jar filename).

.PARAMETER IgnoreModIds
If set, ignores these mod IDs when selecting incompatible mods from logs.

.PARAMETER DryRun
If set, performs no file operations (prints what would happen).

.PARAMETER IncludeWarnMixinsAsIncompatible
If set, also flags WARN "from mod" lines as incompatible (not recommended).

.PARAMETER LogReadRetryCount
Retry count when reading a log that may still be writing.

.PARAMETER LogReadRetryDelayMs
Delay between log read retries.

.PARAMETER LogMaxAgeMinutes
Maximum age (minutes) for additional game logs (latest.log, debug.log, crash reports).
Set to 0 to disable age filtering.

.PARAMETER LogSinceTimestamp
If provided, additional game logs must be newer than this timestamp (with skew).

.PARAMETER LogSinceSkewSeconds
Allowed clock skew (seconds) when filtering by LogSinceTimestamp.

.PARAMETER SkipGameLogs
If set, skips scanning game logs when LogPath is empty.

.PARAMETER DependencyAwareOrderingCountMode
Dependency graph counting mode for prioritizing conflicting mods.

.PARAMETER DependencyAwareTier2MaxDependents
Tier 2 threshold (inclusive).

.PARAMETER DependencyAwareTier3MaxDependents
Tier 3 threshold (inclusive).

.PARAMETER DependencyAwareTreatUnknownAsCore
If true, jars with unknown dependency metadata are treated as tier 4 (core/high-priority).

.PARAMETER DependencyMapSource
Dependency map source: Tool, File, or Internal fallback parser.

.PARAMETER DependencyMapJsonPath
Dependency map JSON path when DependencyMapSource=File.

.PARAMETER DependencyMapToolPath
Path to Analyze-JarDependencyMap.ps1 when DependencyMapSource=Tool.

.PARAMETER DependencyMapOutDir
Output directory for dependency map tool reports.

.PARAMETER Help
Show detailed help for this script and exit.

.EXAMPLE
.\Check-Mod-Compatibility.ps1

.EXAMPLE
.\Check-Mod-Compatibility.ps1 -LogPath "C:\Temp\tl-logger123.txt" -Verbose

.EXAMPLE
.\Check-Mod-Compatibility.ps1 -GameLegacy -Verbose

.EXAMPLE
.\Check-Mod-Compatibility.ps1 -NoLegacy
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  # * Path to tl-logger*.txt or a Fabric log file. Leave empty to auto-pick latest.
  [Parameter(Mandatory = $false)]
  [string]$LogPath = "",

  # * Active mods folder used by the launcher/game.
  [Parameter(Mandatory = $false)]
  [string]$GameModsDir = "",

  # * Main mods storage (the "source of truth").
  [Parameter(Mandatory = $false)]
  [string]$StorageModsDir = "",

  # * Subfolder name inside StorageModsDir where legacy jars will be placed.
  [Parameter(Mandatory = $false)]
  [string]$StorageLegacyFolderName = "Legacy",

  # * Subfolder name inside GameModsDir where removed jars will be placed (keeps them recoverable).
  [Parameter(Mandatory = $false)]
  [string]$GameLegacyFolderName = "legacy",

  # * If set, deletes legacy copies (no legacy storage or game).
  [Parameter(Mandatory = $false)]
  [switch]$NoLegacy,

  # * If set, also keeps legacy copies inside the game mods folder.
  [Parameter(Mandatory = $false)]
  [switch]$GameLegacy,

  # * If set, deletes from GameModsDir instead of moving to GameLegacyFolderName (when enabled).
  [Parameter(Mandatory = $false)]
  [switch]$DeleteFromGameMods,

  # * If set, treats "Found N non-fabric mods" list as incompatible (moves by jar filename).
  [Parameter(Mandatory = $false)]
  [switch]$TreatNonFabricAsIncompatible,

  # * If set, ignores these mod IDs when selecting incompatible mods from logs.
  [Parameter(Mandatory = $false)]
  [string[]]$IgnoreModIds = @(),

  # * If set, performs no file operations (prints what would happen).
  [Parameter(Mandatory = $false)]
  [switch]$DryRun,

  # * If set, also flags WARN "from mod" lines as incompatible (NOT recommended).
  [Parameter(Mandatory = $false)]
  [switch]$IncludeWarnMixinsAsIncompatible,

  # * Retry count when reading a log that may still be writing.
  [Parameter(Mandatory = $false)]
  [int]$LogReadRetryCount = 5,

  # * Delay between log read retries.
  [Parameter(Mandatory = $false)]
  [int]$LogReadRetryDelayMs = 500,

  # * Maximum age (minutes) for additional game logs (latest.log, crash reports).
  [Parameter(Mandatory = $false)]
  [int]$LogMaxAgeMinutes = 30,

  # * Only include game logs written after this timestamp (optional).
  [Parameter(Mandatory = $false)]
  [datetime]$LogSinceTimestamp = [datetime]::MinValue,

  # * Allowed time skew (seconds) when applying LogSinceTimestamp.
  [Parameter(Mandatory = $false)]
  [int]$LogSinceSkewSeconds = 120,

  # * If set, skips scanning game logs (latest.log, crash reports).
  [Parameter(Mandatory = $false)]
  [switch]$SkipGameLogs,

  # * Dependency graph counting mode for priority ordering.
  [Parameter(Mandatory = $false)]
  [ValidateSet("RequiredOnly", "All")]
  [string]$DependencyAwareOrderingCountMode = "RequiredOnly",

  # * Tier 2 threshold (inclusive).
  [Parameter(Mandatory = $false)]
  [int]$DependencyAwareTier2MaxDependents = 3,

  # * Tier 3 threshold (inclusive).
  [Parameter(Mandatory = $false)]
  [int]$DependencyAwareTier3MaxDependents = 10,

  # * If true, unknown metadata is treated as core/high-priority.
  [Parameter(Mandatory = $false)]
  [bool]$DependencyAwareTreatUnknownAsCore = $true,

  # * Dependency map source for priority-aware ordering.
  [Parameter(Mandatory = $false)]
  [ValidateSet("Tool", "File", "Internal")]
  [string]$DependencyMapSource = "Tool",

  # * Dependency map JSON path when DependencyMapSource=File.
  [Parameter(Mandatory = $false)]
  [string]$DependencyMapJsonPath = "",

  # * Path to Analyze-JarDependencyMap.ps1 when DependencyMapSource=Tool.
  [Parameter(Mandatory = $false)]
  [string]$DependencyMapToolPath = "",

  # * Output directory for dependency map tool reports.
  [Parameter(Mandatory = $false)]
  [string]$DependencyMapOutDir = "",

  # * Show detailed help and exit.
  [Parameter(Mandatory = $false)]
  [switch]$Help
)

$sharedLocalizationPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Localization.ps1"
if (-not (Test-Path -LiteralPath $sharedLocalizationPath)) {
  throw ("Shared localization helpers not found: {0}" -f $sharedLocalizationPath)
}
. $sharedLocalizationPath
Initialize-McccLocalization -StartDir $PSScriptRoot | Out-Null
Enable-McccConsoleLocalization

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Help) {
  Get-Help -Full -Name $PSCommandPath
  return
}

$compatLogsEnabled = $PSBoundParameters.ContainsKey("Verbose")

# * Load shared config helpers.
$sharedConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Config.ps1"
if (-not (Test-Path -LiteralPath $sharedConfigPath)) {
  throw ("Shared config helpers not found: {0}" -f $sharedConfigPath)
}
. $sharedConfigPath

$runtimeConfig = Initialize-McccRuntimeConfig `
  -StartDir $PSScriptRoot `
  -BoundParameters $PSBoundParameters `
  -GameModsDir $GameModsDir `
  -StorageModsDir $StorageModsDir `
  -LogPath $LogPath `
  -AlwaysDefaultGameModsDir $true `
  -DefaultStorageToGame $true
$GameModsDir = $runtimeConfig.Paths.GameModsDir
$StorageModsDir = $runtimeConfig.Paths.StorageModsDir
$LogPath = $runtimeConfig.Paths.LogPath

# * Load shared log helpers.
$sharedLogPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-LogTools.ps1"
if (-not (Test-Path -LiteralPath $sharedLogPath)) {
  throw ("Shared log helpers not found: {0}" -f $sharedLogPath)
}
. $sharedLogPath

# * Load shared isolation log helpers.
$sharedIsolationLogPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-LogParsing.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationLogPath)) {
  throw ("Shared isolation log helpers not found: {0}" -f $sharedIsolationLogPath)
}
. $sharedIsolationLogPath

# * Load shared isolation legacy helpers (for persistent logging).
$sharedIsolationLegacyPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-Legacy.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationLegacyPath)) {
  throw ("Shared isolation legacy helpers not found: {0}" -f $sharedIsolationLegacyPath)
}
. $sharedIsolationLegacyPath

# * Load shared dependency helpers (priority ordering and map reuse).
$sharedIsolationJarDepPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Isolation-JarDependencies.ps1"
if (-not (Test-Path -LiteralPath $sharedIsolationJarDepPath)) {
  throw ("Shared isolation jar dependency helpers not found: {0}" -f $sharedIsolationJarDepPath)
}
. $sharedIsolationJarDepPath

function Get-SeverityFromEvidence {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$EvidenceLines
  )

  $hasWarn = $false
  foreach ($line in $EvidenceLines) {
    if ($line -match "\/ERROR\]" -or $line -match "\bERROR\b") {
      return "error"
    }
    if ($line -match "\/WARN\]" -or $line -match "\bWARN\b") {
      $hasWarn = $true
    }
  }
  if ($hasWarn) { return "warn" }
  return "error"
}

function Get-NormalizedEvidenceLine {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Line
  )

  $trimmed = [string]$Line
  if ([string]::IsNullOrWhiteSpace($trimmed)) { return "" }
  $trimmed = $trimmed.Trim()
  # * Collapse whitespace so duplicate evidence from different log sources is counted once.
  return ([regex]::Replace($trimmed, "\s+", " ").ToLowerInvariant())
}

function Get-ModIdSetFromLine {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Line
  )

  if ([string]::IsNullOrWhiteSpace($Line)) { return @() }
  $result = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $idMatches = [regex]::Matches($Line, "\((?<id>[a-z0-9_\-\.]+)\)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  foreach ($m in $idMatches) {
    if (-not $m.Success) { continue }
    $id = [string]$m.Groups["id"].Value
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $null = $result.Add($id.ToLowerInvariant())
  }
  if ($result.Count -eq 0) { return @() }
  return @($result)
}

function Test-HasFabricDialogSignal {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  foreach ($line in $Lines) {
    $text = [string]$line
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    if (
      $text -match "(?i)^\s*Some\s+of\s+your\s+mods\s+are\s+incompatible\b" -or
      $text -match "(?i)^\s*A\s+potential\s+solution\s+has\s+been\s+determined\b" -or
      $text -match "(?i)^\s*More\s+details:\s*$" -or
      $text -match "(?i)^\s*(?:[-*•]\s+)?(?:Remove|Replace)\s+mod\b"
    ) {
      return $true
    }
  }
  return $false
}

function Build-ModIdToJarMap {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DirPath,
    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeDirNames = @()
  )

  $excludeSet = @{}
  foreach ($d in $ExcludeDirNames) { $excludeSet[$d.ToLowerInvariant()] = $true }

  $map = @{}
  $files = Get-ChildItem -LiteralPath $DirPath -Filter "*.jar" -File -ErrorAction Stop |
    Sort-Object -Property LastWriteTime -Descending
  foreach ($f in $files) {
    $ids = Get-FabricModIdsFromJar -JarPath $f.FullName
    if (-not $ids -or $ids.Count -eq 0) { continue }
    foreach ($id in $ids) {
      if (-not $map.ContainsKey($id)) { $map[$id] = New-Object System.Collections.Generic.List[string] }
      $map[$id].Add($f.FullName)
    }
  }
  return $map
}

function Get-LastWriteTimeSafe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    return [datetime]::MinValue
  }
  try {
    return (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTime
  } catch {
    return [datetime]::MinValue
  }
}

function Move-OrDelete {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    [Parameter(Mandatory = $false)]
    [string]$DestDir,
    [Parameter(Mandatory = $true)]
    [bool]$DoDelete,
    [Parameter(Mandatory = $true)]
    [bool]$IsDryRun
  )

  if (-not (Test-Path -LiteralPath $SourcePath)) {
    return $null
  }

  if ($DoDelete) {
    if ($IsDryRun) {
      return ("DRYRUN delete: {0}" -f $SourcePath)
    }
    Remove-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
    return ("deleted: {0}" -f $SourcePath)
  }

  if (-not $DestDir) {
    throw "DestDir is required when DoDelete is false."
  }
  if ($IsDryRun) {
    return ("DRYRUN move: {0} -> {1}" -f $SourcePath, $DestDir)
  }
  New-DirectoryIfMissing -DirPath $DestDir
  $destPath = Join-Path -Path $DestDir -ChildPath ([System.IO.Path]::GetFileName($SourcePath))
  Move-Item -LiteralPath $SourcePath -Destination $destPath -Force -ErrorAction Stop
  return ("moved: {0} -> {1}" -f $SourcePath, $destPath)
}

# * Resolve log paths (supports "latest tl-logger*.txt" fallback).
$primaryLogPath = Get-LatestTLauncherLogPath -PreferredPath $LogPath `
  -SinceTimestamp $LogSinceTimestamp -SinceSkewSeconds $LogSinceSkewSeconds
$primaryLastWrite = [datetime]::MinValue
if (-not [string]::IsNullOrWhiteSpace($primaryLogPath) -and (Test-Path -LiteralPath $primaryLogPath)) {
  $primaryItem = Get-Item -LiteralPath $primaryLogPath -ErrorAction SilentlyContinue
  if ($null -ne $primaryItem) {
    $primaryLastWrite = $primaryItem.LastWriteTime
  }
}
$effectiveSince = $LogSinceTimestamp
if ($effectiveSince -eq [datetime]::MinValue -and $primaryLastWrite -ne [datetime]::MinValue) {
  $effectiveSince = $primaryLastWrite
}
$additionalLogPaths = @()
if (-not $SkipGameLogs -and [string]::IsNullOrWhiteSpace($LogPath)) {
  $additionalLogPaths = Get-AdditionalGameLogPath -GameModsDir $GameModsDir
  $additionalLogPaths = Select-RecentLogPath -Paths $additionalLogPaths -MaxAgeMinutes $LogMaxAgeMinutes `
    -SinceTimestamp $effectiveSince -SinceSkewSeconds $LogSinceSkewSeconds
}
$resolvedLogPaths = Resolve-LogPath -PrimaryPath $primaryLogPath -AdditionalPaths $additionalLogPaths
$resolvedLogPaths = @($resolvedLogPaths)

$logLinesBySource = @{}
foreach ($logPath in $resolvedLogPaths) {
  $lines = Read-LogLinesWithRetry -Path $logPath -Retries $LogReadRetryCount -DelayMs $LogReadRetryDelayMs
  if ($lines -is [string]) {
    $lines = @($lines)
  }
  if ($null -eq $lines) {
    $lines = @()
  }
  $lines = $lines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
  $logLinesBySource[$logPath] = $lines
}

$allLogLines = @()
foreach ($logPath in $logLinesBySource.Keys) {
  $allLogLines += $logLinesBySource[$logPath]
}
$logLineCount = Get-LineCountSafe -Lines $allLogLines
if ($logLineCount -eq 0) {
  Write-Host ("Logs are empty or unreadable: {0}" -f ($resolvedLogPaths -join "; ")) -ForegroundColor Red
  exit 2
}
$mcVersion = Get-MinecraftVersionFromLog -Lines $allLogLines

Write-Host ("Log: {0}" -f $primaryLogPath) -ForegroundColor Cyan
if ($resolvedLogPaths.Count -gt 1) {
  $additionalList = @($resolvedLogPaths | Where-Object { $_ -ne $primaryLogPath })
  if ($additionalList -and $additionalList.Count -gt 0) {
    Write-Host ("Additional logs: {0}" -f ($additionalList -join "; ")) -ForegroundColor Cyan
  }
}
Write-Host ("Minecraft: {0}" -f $mcVersion) -ForegroundColor Cyan

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
    Write-Host ("Ignoring incompatible mod IDs: {0}" -f ($ignoredLabel -join ", ")) -ForegroundColor Gray
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
    Write-Host ("Fabric conflict-priority deferred secondary mod IDs: {0}" -f ($fabricConflictDeferredModIds -join ", ")) -ForegroundColor Gray
  }
}

# * Legacy.log is now maintained as a persistent culprit-move log by Auto-Run-LegacyLauncher.
# * Evidence logging removed; culprit entries are appended by Layer-Mods / Isolate scripts.

if ($evidenceByModId.Count -eq 0 -and (-not $TreatNonFabricAsIncompatible)) {
  Write-Host "No incompatible mods detected from current log patterns." -ForegroundColor Green
  exit 0
}

if (-not (Test-Path -LiteralPath $GameModsDir)) {
  throw ("GameModsDir not found: {0}" -f $GameModsDir)
}
if (-not (Test-Path -LiteralPath $StorageModsDir)) {
  throw ("StorageModsDir not found: {0}" -f $StorageModsDir)
}

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

# * Build mod id -> jar mapping for game mods dir.
$gameIdToJars = Build-ModIdToJarMap -DirPath $GameModsDir

# * For storage, prefer filename match, then fallback to id scan of root jars.
$storageRootJars = Get-ChildItem -LiteralPath $StorageModsDir -Filter "*.jar" -File -ErrorAction Stop |
  ForEach-Object { $_.FullName }
$storageFileNameToPath = @{}
foreach ($p in $storageRootJars) {
  $storageFileNameToPath[[System.IO.Path]::GetFileName($p).ToLowerInvariant()] = $p
}
$storageIdToJars = Build-ModIdToJarMap -DirPath $StorageModsDir

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
    Write-Host ("Warning: dependency map unavailable from source '{0}'. Falling back to internal parser." -f $DependencyMapSource) -ForegroundColor Yellow
  }
  $depCountMap = Get-DependentModCountsByJarName -ModsDir $GameModsDir -CountMode $countMode
  $dependencyPrioritySourceUsed = "Internal"
}

if ($DependencyMapSource -eq "File") {
  $dependencyPriorityMapJsonPath = $DependencyMapJsonPath
  if ([string]::IsNullOrWhiteSpace($dependencyPriorityMapJsonPath)) {
    $dependencyPriorityMapJsonPath = Join-Path -Path $PSScriptRoot -ChildPath "..\reports\jar-dependency-map.json"
  }
} elseif ($DependencyMapSource -eq "Tool") {
  $mapOutDir = $DependencyMapOutDir
  if ([string]::IsNullOrWhiteSpace($mapOutDir)) {
    $mapOutDir = Join-Path -Path $PSScriptRoot -ChildPath "..\reports"
  }
  $dependencyPriorityMapJsonPath = Join-Path -Path $mapOutDir -ChildPath "jar-dependency-map.json"
}
if (-not [string]::IsNullOrWhiteSpace($dependencyPriorityMapJsonPath) -and (Test-Path -LiteralPath $dependencyPriorityMapJsonPath)) {
  $dependencyPriorityMapJsonPath = (Resolve-Path -LiteralPath $dependencyPriorityMapJsonPath).Path
}

$gameRootJars = @(Get-ChildItem -LiteralPath $GameModsDir -Filter "*.jar" -File -ErrorAction Stop)
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

$actions = New-Object System.Collections.Generic.List[object]

foreach ($modId in $orderedModIds) {
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
  if ($gameIdToJars.ContainsKey($modId)) { $gameJarPaths = @($gameIdToJars[$modId]) }
  if ($gameJarPaths -and $gameJarPaths.Count -gt 1) {
    $gameJarSortProps = @(
      @{ Expression = { Get-LastWriteTimeSafe -Path $_ }; Descending = $true }
      @{ Expression = { $_ }; Ascending = $true }
    )
    $gameJarPaths = @($gameJarPaths | Sort-Object -Property $gameJarSortProps)
  }

  if (-not $gameJarPaths -or $gameJarPaths.Count -eq 0) {
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
    continue
  }

  foreach ($gameJarPath in $gameJarPaths) {
    $gameFileName = [System.IO.Path]::GetFileName($gameJarPath)
    $storageJarPath = $null
    $storageKey = $gameFileName.ToLowerInvariant()
    if ($storageFileNameToPath.ContainsKey($storageKey)) {
      $storageJarPath = $storageFileNameToPath[$storageKey]
    } elseif ($storageIdToJars.ContainsKey($modId) -and $storageIdToJars[$modId].Count -gt 0) {
      $storageJarPath = $storageIdToJars[$modId][0]
    }

    $gameResult = $null
    if ($DryRun) {
        $gameResult = Move-OrDelete -SourcePath $gameJarPath -DestDir $gameLegacyVersionDir -DoDelete $deleteFromGame -IsDryRun $true
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
        }
    }

    $storageResult = $null
    if ($DryRun) {
        if ($storageJarPath) {
            $storageResult = Move-OrDelete -SourcePath $storageJarPath -DestDir $storageLegacyVersionDir -DoDelete $deleteFromStorage -IsDryRun $true
        } else {
            $storageResult = ("not found in storage root for file '{0}' (modId '{1}')" -f $gameFileName, $modId)
        }
    } else {
        # * Storage result is already handled by Move-CulpritToLegacyAndAppendLog above.
        if ($storageJarPath) {
            if ($null -ne $moveResult -and $moveResult.StorageMoved) {
                $storageResult = if ($deleteFromStorage) { "deleted: $storageJarPath" } else { "moved: $storageJarPath -> $storageLegacyVersionDir" }
            } else {
                $storageResult = "failed to move from storage"
            }
        } else {
            $storageResult = ("not found in storage root for file '{0}' (modId '{1}')" -f $gameFileName, $modId)
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
            }
        } else {
            $gameResult = ("not present in game mods: {0}" -f $jarName)
        }

        if (Test-Path -LiteralPath $storagePath) {
            if ($moveResult.StorageMoved) {
                $storageResult = if ($deleteFromStorage) { "deleted: $storagePath" } else { "moved: $storagePath -> $storageLegacyVersionDir" }
            } else {
                $storageResult = "failed to move from storage"
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
}

if ($compatLogsEnabled) {
  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $outPath = Join-Path -Path $PSScriptRoot -ChildPath ("compat-report-{0}.json" -f $timestamp)
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

$handledActions = @($actions | Where-Object { $_.status -in @("handled", "handled_non_fabric_by_filename") })
if ($actions.Count -gt 0 -and $handledActions.Count -eq 0) {
  Write-Host "No removable mods found in game mods folder. Check missing dependencies or mod ids." -ForegroundColor Yellow
  exit 3
}

exit 0
