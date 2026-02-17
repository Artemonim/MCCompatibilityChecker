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
DEPRECATED: Optional override path to Analyze-JarDependencyMap.ps1 when DependencyMapSource=Tool.
Prefer the bundled default tool path; keep override only for troubleshooting.

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
  [string]$StorageLegacyFolderName = "",

  # * Subfolder name inside GameModsDir where removed jars will be placed (keeps them recoverable).
  [Parameter(Mandatory = $false)]
  [string]$GameLegacyFolderName = "",

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

  # ! DEPRECATED: Custom dependency-map tool path override is kept for backward compatibility.
  # * Prefer the bundled default tool path unless troubleshooting requires an override.
  [Parameter(Mandatory = $false)]
  [string]$DependencyMapToolPath = "",

  # * Output directory for dependency map tool reports.
  [Parameter(Mandatory = $false)]
  [string]$DependencyMapOutDir = "",

  # * Show detailed help and exit.
  [Parameter(Mandatory = $false)]
  [switch]$Help
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

$compatLogsEnabled = $PSBoundParameters.ContainsKey("Verbose")

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
$projectRootPath = [string]$runtimeBootstrap.ProjectRoot

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

# * Load shared file operation and folder policy helpers.
$sharedFileOpsPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-FileOps.ps1"
if (-not (Test-Path -LiteralPath $sharedFileOpsPath)) {
  throw ("Shared file operation helpers not found: {0}" -f $sharedFileOpsPath)
}
. $sharedFileOpsPath

# * Load shared stage result helpers.
$sharedStageResultPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-StageResult.ps1"
if (-not (Test-Path -LiteralPath $sharedStageResultPath)) {
  throw ("Shared stage result helpers not found: {0}" -f $sharedStageResultPath)
}
. $sharedStageResultPath

$resolvedLegacyFolders = Resolve-McccLegacyFolderNames `
  -GameLegacyFolderName $GameLegacyFolderName `
  -StorageLegacyFolderName $StorageLegacyFolderName
$GameLegacyFolderName = [string]$resolvedLegacyFolders.GameLegacyFolderName
$StorageLegacyFolderName = [string]$resolvedLegacyFolders.StorageLegacyFolderName

$checkCompatibilityEvidencePath = Join-Path -Path $PSScriptRoot -ChildPath "Check-Mod-Compatibility.Evidence.ps1"
if (-not (Test-Path -LiteralPath $checkCompatibilityEvidencePath)) {
  throw ("Check compatibility evidence stage script not found: {0}" -f $checkCompatibilityEvidencePath)
}

$checkCompatibilityModResolutionPath = Join-Path -Path $PSScriptRoot -ChildPath "Check-Mod-Compatibility.ModResolution.ps1"
if (-not (Test-Path -LiteralPath $checkCompatibilityModResolutionPath)) {
  throw ("Check compatibility mod resolution stage script not found: {0}" -f $checkCompatibilityModResolutionPath)
}

$checkCompatibilityDecisionPath = Join-Path -Path $PSScriptRoot -ChildPath "Check-Mod-Compatibility.Decision.ps1"
if (-not (Test-Path -LiteralPath $checkCompatibilityDecisionPath)) {
  throw ("Check compatibility decision stage script not found: {0}" -f $checkCompatibilityDecisionPath)
}

$checkCompatibilityReportingPath = Join-Path -Path $PSScriptRoot -ChildPath "Check-Mod-Compatibility.Reporting.ps1"
if (-not (Test-Path -LiteralPath $checkCompatibilityReportingPath)) {
  throw ("Check compatibility reporting stage script not found: {0}" -f $checkCompatibilityReportingPath)
}

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
  $addCandidate = {
    param(
      [Parameter(Mandatory = $true)]
      [string]$Candidate
    )
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return }
    $normalized = $Candidate.Trim().ToLowerInvariant()
    if ($normalized -notmatch "[a-z]") { return }
    $null = $result.Add($normalized)
  }

  $parenMatches = [regex]::Matches($Line, "\((?<id>[a-z0-9_\-\.]+)\)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  foreach ($m in @($parenMatches)) {
    if (-not $m.Success) { continue }
    & $addCandidate ([string]$m.Groups["id"].Value)
  }

  $fixLinePatterns = @(
    "(?i)\bremove\s+\[(?<id>[a-z0-9_\-\.]+)\b",
    "(?i)\[\[(?<id>[a-z0-9_\-\.]+)\b",
    "(?i)\badd:(?<id>[a-z0-9_\-\.]+)\b"
  )
  foreach ($pattern in $fixLinePatterns) {
    $patternMatches = [regex]::Matches($Line, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in @($patternMatches)) {
      if (-not $m.Success) { continue }
      & $addCandidate ([string]$m.Groups["id"].Value)
    }
  }

  foreach ($reasonId in @(Get-FabricReasonCandidateModIdList -Line $Line)) {
    & $addCandidate ([string]$reasonId)
  }

  $reasonTargetPatterns = @(
    "(?i)\bbreaks\s+(?<id>[a-z0-9_\-\.]+)\b",
    "(?i)\bdepends\s+(?<id>[a-z0-9_\-\.]+)\b"
  )
  foreach ($pattern in $reasonTargetPatterns) {
    $targetMatches = [regex]::Matches($Line, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in @($targetMatches)) {
      if (-not $m.Success) { continue }
      & $addCandidate ([string]$m.Groups["id"].Value)
    }
  }

  if ($result.Count -eq 0) { return @() }
  return @($result)
}

function Get-ModIdLookupVariantList {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModId
  )

  if ([string]::IsNullOrWhiteSpace($ModId)) { return @() }
  $id = $ModId.Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($id)) { return @() }

  $variants = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $null = $variants.Add($id)
  $null = $variants.Add($id.Replace("-", "_"))
  $null = $variants.Add($id.Replace("_", "-"))

  if ($id -match '[_\-]mixin$') {
    $base = [regex]::Replace($id, '[_\-]mixin$', '')
    if (-not [string]::IsNullOrWhiteSpace($base)) {
      $null = $variants.Add($base)
      $null = $variants.Add(("{0}_modloader" -f $base))
      $null = $variants.Add(("{0}-modloader" -f $base))
    }
  }

  if ($id -match '[_\-]modloader$') {
    $base = [regex]::Replace($id, '[_\-]modloader$', '')
    if (-not [string]::IsNullOrWhiteSpace($base)) {
      $null = $variants.Add($base)
      $null = $variants.Add(("{0}_mixin" -f $base))
      $null = $variants.Add(("{0}-mixin" -f $base))
    }
  }

  return @($variants | Sort-Object)
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
      $text -match "(?i)\bSome\s+of\s+your\s+mods\s+are\s+incompatible\b" -or
      $text -match "(?i)\bA\s+potential\s+solution\s+has\s+been\s+determined\b" -or
      $text -match "(?i)^\s*More\s+details:\s*$" -or
      $text -match "(?i)^\s*(?:[-*•]\s+)?(?:Remove|Replace)\s+mod\b" -or
      $text -match "(?i)\bFix:\s+add\s+\[" -or
      $text -match "(?i)\b(?:Immediate\s+reason|Reason):\s+\["
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
    [string[]]$ExcludeDirNames = @(),
    [Parameter(Mandatory = $false)]
    [bool]$IncludeNestedJarIds = $false,
    [Parameter(Mandatory = $false)]
    [int]$NestedJarScanDepth = 2
  )

  $files = @(Get-McccJarFiles -RootPaths @($DirPath) -SortBy "LastWriteTime" -Descending $true -ExcludeDirectoryNames $ExcludeDirNames -EnumerationErrorAction "Stop")
  if (-not $files -or $files.Count -eq 0) { return @{} }

  $metadataByJarPath = @{}
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($file in @($files)) {
    if ($null -eq $file) { continue }
    $jarPath = [string]$file.FullName
    if ([string]::IsNullOrWhiteSpace($jarPath)) { continue }

    $modIds = @(Get-McccCachedJarMetadata -JarPath $jarPath -Cache $metadataByJarPath -GetMetadata {
        param($cachedJarPath)
        @(Get-FabricModIdsFromJar -JarPath $cachedJarPath -IncludeNestedJarIds $IncludeNestedJarIds -MaxNestedJarDepth $NestedJarScanDepth)
      })
    if (-not $modIds -or $modIds.Count -eq 0) { continue }

    $rows.Add([pscustomobject]@{
        JarPath = $jarPath
        ModIds = @($modIds)
      }) | Out-Null
  }

  return New-McccModIdJarPathIndex `
    -Items @($rows.ToArray()) `
    -GetJarPath { param($entry) [string]$entry.JarPath } `
    -GetModIds { param($entry) @($entry.ModIds) }
}

function Resolve-ModJarPathsByNestedFallback {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DirPath,
    [Parameter(Mandatory = $true)]
    [string]$ModId,
    [Parameter(Mandatory = $true)]
    [hashtable]$ResolvedByModIdCache,
    [Parameter(Mandatory = $true)]
    [hashtable]$JarIdsByPathCache,
    [Parameter(Mandatory = $false)]
    [int]$MaxNestedJarDepth = 1
  )

  if ([string]::IsNullOrWhiteSpace($DirPath) -or -not (Test-Path -LiteralPath $DirPath)) { return @() }
  if ([string]::IsNullOrWhiteSpace($ModId)) { return @() }
  if ($MaxNestedJarDepth -lt 0) { $MaxNestedJarDepth = 0 }

  $modKey = $ModId.ToLowerInvariant()
  if ($ResolvedByModIdCache.ContainsKey($modKey)) {
    return @($ResolvedByModIdCache[$modKey])
  }

  $result = New-Object System.Collections.Generic.List[string]
  $jarFiles = @(Get-McccJarFiles -RootPaths @($DirPath) -SortBy "LastWriteTime" -Descending $true -EnumerationErrorAction "SilentlyContinue")
  foreach ($jarFile in @($jarFiles)) {
    if ($null -eq $jarFile) { continue }
    $jarPath = [string]$jarFile.FullName
    if ([string]::IsNullOrWhiteSpace($jarPath)) { continue }

    # * Keep fallback lightweight: read direct IDs and nested entry names only.
    # * Parsing full nested jars here can be memory-heavy on large packs.
    $cachedMetadata = Get-McccCachedJarMetadata -JarPath $jarPath -Cache $JarIdsByPathCache -GetMetadata {
      param($cachedJarPath)
      [pscustomobject]@{
        Ids = @(Get-FabricModIdsFromJar -JarPath $cachedJarPath)
        NestedJarEntryPaths = @(Get-FabricNestedJarEntryPathsFromJar -JarPath $cachedJarPath)
      }
    }

    $jarIds = @()
    $nestedJarEntryPaths = @()
    if ($cachedMetadata -is [pscustomobject]) {
      if ($cachedMetadata.PSObject.Properties.Match("Ids").Count -gt 0) {
        $jarIds = @($cachedMetadata.Ids)
      }
      if ($cachedMetadata.PSObject.Properties.Match("NestedJarEntryPaths").Count -gt 0) {
        $nestedJarEntryPaths = @($cachedMetadata.NestedJarEntryPaths)
      }
    } else {
      $jarIds = @($cachedMetadata)
    }
    if ((-not $jarIds -or $jarIds.Count -eq 0) -and (-not $nestedJarEntryPaths -or $nestedJarEntryPaths.Count -eq 0)) { continue }

    $isMatch = $false
    foreach ($jarId in @($jarIds)) {
      $id = [string]$jarId
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      if ($id.ToLowerInvariant() -ne $modKey) { continue }
      $isMatch = $true
      break
    }

    if (-not $isMatch -and $nestedJarEntryPaths -and $nestedJarEntryPaths.Count -gt 0) {
      foreach ($nestedEntryPath in @($nestedJarEntryPaths)) {
        $nestedPath = [string]$nestedEntryPath
        if ([string]::IsNullOrWhiteSpace($nestedPath)) { continue }
        $nestedName = [System.IO.Path]::GetFileName($nestedPath)
        if (Test-JarNameMatchesAnyId -JarName $nestedName -Ids @($modKey) -AllowTokenMatch $false) {
          $isMatch = $true
          break
        }
      }
    }

    if ($isMatch) {
      $result.Add($jarPath) | Out-Null
    }
  }

  $resolved = @($result.ToArray() | Sort-Object -Unique)
  $ResolvedByModIdCache[$modKey] = @($resolved)
  return @($resolved)
}

function Get-MixinConfigNameHintsFromEvidence {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$EvidenceLines = @()
  )

  if (-not $EvidenceLines -or $EvidenceLines.Count -eq 0) { return @() }
  $hints = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $patterns = @(
    "Mixin apply for mod\s+[a-z0-9_\-\.]+\s+failed\s+(?<ref>\S+)",
    "@Mixin target\s+\S+\s+was not found\s+(?<ref>\S+)"
  )

  foreach ($line in @($EvidenceLines)) {
    $text = [string]$line
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    foreach ($pattern in @($patterns)) {
      $m = [regex]::Match($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      if (-not $m.Success) { continue }
      $mixinRef = [string]$m.Groups["ref"].Value
      if ([string]::IsNullOrWhiteSpace($mixinRef)) { continue }

      $mixinConfig = $mixinRef.Trim()
      $splitIndex = $mixinConfig.IndexOf(":")
      if ($splitIndex -ge 0) {
        $mixinConfig = $mixinConfig.Substring(0, $splitIndex)
      }
      $mixinConfig = $mixinConfig.Trim().Trim([char[]]@('"', "'")).Replace("\", "/")
      if ([string]::IsNullOrWhiteSpace($mixinConfig)) { continue }

      $null = $hints.Add($mixinConfig.ToLowerInvariant())
      $fileName = [System.IO.Path]::GetFileName($mixinConfig)
      if (-not [string]::IsNullOrWhiteSpace($fileName)) {
        $null = $hints.Add($fileName.ToLowerInvariant())
      }
      break
    }
  }

  if ($hints.Count -eq 0) { return @() }
  return @($hints | Sort-Object)
}

function Get-MixinConfigEntryLookupForJar {
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarPath,
    [Parameter(Mandatory = $true)]
    [hashtable]$JarMixinConfigEntryCache
  )

  if ($JarMixinConfigEntryCache.ContainsKey($JarPath)) {
    return $JarMixinConfigEntryCache[$JarPath]
  }

  $entries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  if ([string]::IsNullOrWhiteSpace($JarPath) -or -not (Test-Path -LiteralPath $JarPath)) {
    $JarMixinConfigEntryCache[$JarPath] = $entries
    return $entries
  }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = $null
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    foreach ($zipEntry in @($zip.Entries)) {
      if ($null -eq $zipEntry) { continue }
      $entryName = [string]$zipEntry.FullName
      if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
      $entryKey = $entryName.Trim().Replace("\", "/").ToLowerInvariant()
      if (-not $entryKey.EndsWith(".json", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      if ($entryKey -notmatch "mixin") { continue }
      $null = $entries.Add($entryKey)
      $fileName = [System.IO.Path]::GetFileName($entryKey)
      if (-not [string]::IsNullOrWhiteSpace($fileName)) {
        $null = $entries.Add($fileName.ToLowerInvariant())
      }
    }
  } catch {
    Write-Verbose ("Failed to read mixin config entries from '{0}': {1}" -f $JarPath, $_.Exception.Message)
  } finally {
    if ($null -ne $zip) { $zip.Dispose() }
  }

  $JarMixinConfigEntryCache[$JarPath] = $entries
  return $entries
}

function Select-GameJarPathsByMixinEvidence {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModId,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$CandidateJarPaths = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$EvidenceLines = @(),
    [Parameter(Mandatory = $true)]
    [hashtable]$JarMixinConfigEntryCache
  )

  if (-not $CandidateJarPaths -or $CandidateJarPaths.Count -le 1) { return @($CandidateJarPaths) }
  $mixinHints = @(Get-MixinConfigNameHintsFromEvidence -EvidenceLines $EvidenceLines)
  if (-not $mixinHints -or $mixinHints.Count -eq 0) { return @($CandidateJarPaths) }

  $matchedPaths = New-Object System.Collections.Generic.List[string]
  foreach ($jarPath in @($CandidateJarPaths)) {
    $pathValue = [string]$jarPath
    if ([string]::IsNullOrWhiteSpace($pathValue)) { continue }
    $entryLookup = Get-MixinConfigEntryLookupForJar -JarPath $pathValue -JarMixinConfigEntryCache $JarMixinConfigEntryCache
    if ($null -eq $entryLookup) { continue }
    foreach ($hint in @($mixinHints)) {
      $hintKey = [string]$hint
      if ([string]::IsNullOrWhiteSpace($hintKey)) { continue }
      if (-not $entryLookup.Contains($hintKey.ToLowerInvariant())) { continue }
      $matchedPaths.Add($pathValue) | Out-Null
      break
    }
  }

  if ($matchedPaths.Count -eq 0 -or $matchedPaths.Count -ge $CandidateJarPaths.Count) {
    return @($CandidateJarPaths)
  }

  $selected = @($matchedPaths.ToArray() | Sort-Object -Unique)
  $selectedNames = @($selected | ForEach-Object { [System.IO.Path]::GetFileName([string]$_) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
  if ($selectedNames.Count -gt 0) {
    Write-Host ("Disambiguated mod '{0}' by Mixin config evidence. Selected jar(s): {1}" -f $ModId, ($selectedNames -join ", ")) -ForegroundColor Gray
  }
  return @($selected)
}

function Resolve-GameJarPathsFromMixinEvidence {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModId,
    [Parameter(Mandatory = $true)]
    [string]$ModsDir,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$EvidenceLines = @(),
    [Parameter(Mandatory = $true)]
    [hashtable]$JarMixinConfigEntryCache
  )

  if ([string]::IsNullOrWhiteSpace($ModsDir) -or -not (Test-Path -LiteralPath $ModsDir)) { return @() }
  $mixinHints = @(Get-MixinConfigNameHintsFromEvidence -EvidenceLines $EvidenceLines)
  if (-not $mixinHints -or $mixinHints.Count -eq 0) { return @() }

  $matchedPaths = New-Object System.Collections.Generic.List[string]
  $jarFiles = @(Get-McccJarFiles -RootPaths @($ModsDir) -SortBy "LastWriteTime" -Descending $true -EnumerationErrorAction "SilentlyContinue")
  foreach ($jarFile in @($jarFiles)) {
    if ($null -eq $jarFile) { continue }
    $jarPath = [string]$jarFile.FullName
    if ([string]::IsNullOrWhiteSpace($jarPath)) { continue }

    $entryLookup = Get-MixinConfigEntryLookupForJar -JarPath $jarPath -JarMixinConfigEntryCache $JarMixinConfigEntryCache
    if ($null -eq $entryLookup) { continue }
    foreach ($hint in @($mixinHints)) {
      $hintKey = [string]$hint
      if ([string]::IsNullOrWhiteSpace($hintKey)) { continue }
      if (-not $entryLookup.Contains($hintKey.ToLowerInvariant())) { continue }
      $matchedPaths.Add($jarPath) | Out-Null
      break
    }
  }

  if ($matchedPaths.Count -eq 0) { return @() }
  $resolved = @($matchedPaths.ToArray() | Sort-Object -Unique)
  $resolvedNames = @($resolved | ForEach-Object { [System.IO.Path]::GetFileName([string]$_) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

  $baseId = [string]$ModId
  if (-not [string]::IsNullOrWhiteSpace($baseId)) {
    $baseId = $baseId.Trim().ToLowerInvariant()
    $baseId = [regex]::Replace($baseId, '[_\-](mixin|modloader)$', '')
    if (-not [string]::IsNullOrWhiteSpace($baseId) -and $baseId.Length -ge 3) {
      $baseNameMatched = @($resolved | Where-Object { [System.IO.Path]::GetFileName([string]$_).ToLowerInvariant() -like ("*{0}*" -f $baseId) })
      if ($baseNameMatched.Count -gt 0 -and $baseNameMatched.Count -lt $resolved.Count) {
        $resolved = @($baseNameMatched | Sort-Object -Unique)
        $resolvedNames = @($resolved | ForEach-Object { [System.IO.Path]::GetFileName([string]$_) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
      }
    }
  }

  if ($resolvedNames.Count -gt 0) {
    Write-Host ("Disambiguated mod '{0}' by Mixin config evidence. Selected jar(s): {1}" -f $ModId, ($resolvedNames -join ", ")) -ForegroundColor Gray
  }
  return @($resolved)
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

  if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path -LiteralPath $SourcePath)) {
    return $null
  }

  if ($DoDelete) {
    $removeResult = Remove-McccItem `
      -LiteralPath $SourcePath `
      -DryRun $IsDryRun `
      -Overwrite $true `
      -RetryCount 0 `
      -RetryDelayMs 0
    if (-not $removeResult.SourceExists) {
      return $null
    }
    if ($IsDryRun) {
      return ("DRYRUN delete: {0}" -f $SourcePath)
    }
    if ($removeResult.Performed) {
      return ("deleted: {0}" -f $SourcePath)
    }
    return $null
  }

  if (-not $DestDir) {
    throw "DestDir is required when DoDelete is false."
  }
  if ($IsDryRun) {
    return ("DRYRUN move: {0} -> {1}" -f $SourcePath, $DestDir)
  }
  $destPath = Join-McccDestinationPath -SourcePath $SourcePath -DestinationDirectory $DestDir
  $moveResult = Move-McccItem `
    -LiteralPath $SourcePath `
    -DestinationPath $destPath `
    -DryRun $false `
    -Overwrite $true `
    -RetryCount 0 `
    -RetryDelayMs 0
  if (-not $moveResult.Performed) {
    return $null
  }
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

# * Internal stage contracts shared between SRP stage scripts.
$checkCompatStageResults = @{}

. $checkCompatibilityEvidencePath

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

. $checkCompatibilityModResolutionPath
. $checkCompatibilityDecisionPath
. $checkCompatibilityReportingPath

if ($null -eq $script:checkCompatExitCode) {
  $script:checkCompatExitCode = 0
}

exit ([int]$script:checkCompatExitCode)
