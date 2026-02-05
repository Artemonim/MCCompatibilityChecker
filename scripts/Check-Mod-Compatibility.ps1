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

.PARAMETER SkipGameLogs
If set, skips scanning game logs when LogPath is empty.

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
  [string]$GameModsDir = "C:\Users\Artem\AppData\Roaming\.tlauncher\legacy\Minecraft\game\mods",

  # * Main mods storage (the "source of truth").
  [Parameter(Mandatory = $false)]
  [string]$StorageModsDir = "D:\Установщики игр\MineCraft 1.21\Mods",

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

  # * If set, skips scanning game logs (latest.log, crash reports).
  [Parameter(Mandatory = $false)]
  [switch]$SkipGameLogs,

  # * Show detailed help and exit.
  [Parameter(Mandatory = $false)]
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Help) {
  Get-Help -Full -Name $PSCommandPath
  return
}

$compatLogsEnabled = $PSBoundParameters.ContainsKey("Verbose")

function Get-LatestTLauncherLogPath {
  param(
    [Parameter(Mandatory = $false)]
    [string]$PreferredPath
  )

  if (-not [string]::IsNullOrWhiteSpace($PreferredPath) -and (Test-Path -LiteralPath $PreferredPath)) {
    return $PreferredPath
  }

  $tempDir = [System.IO.Path]::GetTempPath()
  $candidates = Get-ChildItem -LiteralPath $tempDir -Filter "tl-logger*.txt" -File -ErrorAction SilentlyContinue |
    Sort-Object -Property LastWriteTime -Descending
  if (-not $candidates -or $candidates.Count -eq 0) {
    throw ("Could not find tl-logger*.txt in temp dir: {0}" -f $tempDir)
  }
  return $candidates[0].FullName
}

function Get-GameRootFromModsDir {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModsDir
  )

  if ([string]::IsNullOrWhiteSpace($ModsDir)) { return $null }
  $parent = Split-Path -Path $ModsDir -Parent
  if ([string]::IsNullOrWhiteSpace($parent)) { return $null }
  if (-not (Test-Path -LiteralPath $parent)) { return $null }
  return $parent
}

function Get-AdditionalGameLogPaths {
  param(
    [Parameter(Mandatory = $true)]
    [string]$GameModsDir
  )

  $paths = New-Object System.Collections.Generic.List[string]
  $gameRoot = Get-GameRootFromModsDir -ModsDir $GameModsDir
  if (-not $gameRoot) { return $paths }

  $logsDir = Join-Path -Path $gameRoot -ChildPath "logs"
  foreach ($name in @("latest.log", "debug.log")) {
    $candidate = Join-Path -Path $logsDir -ChildPath $name
    if (Test-Path -LiteralPath $candidate) { $paths.Add($candidate) }
  }

  $crashDir = Join-Path -Path $gameRoot -ChildPath "crash-reports"
  if (Test-Path -LiteralPath $crashDir) {
    $latestCrash = Get-ChildItem -LiteralPath $crashDir -Filter "*.txt" -File -ErrorAction SilentlyContinue |
      Sort-Object -Property LastWriteTime -Descending |
      Select-Object -First 1
    if ($latestCrash) { $paths.Add($latestCrash.FullName) }
  }

  return $paths
}

function Select-RecentLogPaths {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Paths,
    [Parameter(Mandatory = $true)]
    [int]$MaxAgeMinutes
  )

  if (-not $Paths -or $Paths.Count -eq 0) { return @() }
  if ($MaxAgeMinutes -le 0) { return $Paths }

  $cutoff = (Get-Date).AddMinutes(-$MaxAgeMinutes)
  $recent = New-Object System.Collections.Generic.List[string]
  foreach ($path in $Paths) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($null -ne $item -and $item.LastWriteTime -ge $cutoff) {
      $recent.Add($path)
    }
  }
  return $recent
}

function Resolve-LogPaths {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PrimaryPath,
    [Parameter(Mandatory = $false)]
    [string[]]$AdditionalPaths = @()
  )

  $resolved = New-Object System.Collections.Generic.List[string]
  $seen = @{}

  if (-not [string]::IsNullOrWhiteSpace($PrimaryPath)) {
    $resolved.Add($PrimaryPath)
    $seen[$PrimaryPath.ToLowerInvariant()] = $true
  }

  foreach ($path in $AdditionalPaths) {
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    $key = $path.ToLowerInvariant()
    if (-not $seen.ContainsKey($key)) {
      $resolved.Add($path)
      $seen[$key] = $true
    }
  }

  return $resolved
}

function Read-AllLinesUtf8BestEffort {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )
  try {
    return [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
  } catch {
    # ! Some logs can be ANSI/Windows-1251 depending on tooling; fall back to default encoding.
    return Get-Content -LiteralPath $Path -ErrorAction Stop
  }
}

function Get-LineCountSafe {
  param(
    [Parameter(Mandatory = $false)]
    $Lines
  )

  if ($null -eq $Lines) { return 0 }
  if ($Lines -is [string]) {
    if ([string]::IsNullOrWhiteSpace($Lines)) { return 0 }
    return 1
  }
  $count = 0
  foreach ($line in $Lines) {
    if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
      $count++
    }
  }
  return $count
}

function Read-LogLinesWithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [int]$Retries,
    [Parameter(Mandatory = $true)]
    [int]$DelayMs
  )

  for ($i = 0; $i -le $Retries; $i++) {
    $lines = Read-AllLinesUtf8BestEffort -Path $Path
    $count = Get-LineCountSafe -Lines $lines
    if ($count -gt 0) {
      return $lines
    }
    if ($i -lt $Retries) {
      Start-Sleep -Milliseconds $DelayMs
    }
  }
  return $lines
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

function Write-LegacyLog {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$EvidenceByModId,
    [Parameter(Mandatory = $true)]
    [string]$LogPath
  )

  if ($EvidenceByModId.Count -eq 0) { return }
  foreach ($modId in ($EvidenceByModId.Keys | Sort-Object)) {
    $lines = @($EvidenceByModId[$modId])
    $severity = Get-SeverityFromEvidence -EvidenceLines $lines
    Add-Content -LiteralPath $LogPath -Value ("[{0}]: {1}" -f $severity, $modId)
  }
}

function Get-MinecraftVersionFromLog {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, "Loading Minecraft\s+(?<ver>\S+)\s+with Fabric Loader", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) { return $m.Groups["ver"].Value }
  }

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, "^\s*-\s+minecraft\s+(?<ver>\S+)\s*$", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) { return $m.Groups["ver"].Value }
  }

  return "unknown"
}

function Get-NonFabricJarNamesFromLog {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  $inSection = $false
  $names = New-Object System.Collections.Generic.List[string]

  foreach ($line in $Lines) {
    if ($line -match "Found\s+\d+\s+non-fabric\s+mods") {
      $inSection = $true
      continue
    }
    if ($inSection) {
      if ($line -match "^\s*-\s+(?<jar>.+?\.jar)\s*$") {
        $names.Add($Matches["jar"])
        continue
      }
      # * Section ends on first non-bullet line.
      if ($line -notmatch "^\s*-\s+") {
        break
      }
    }
  }
  return $names
}

function Get-IncompatibleModEvidenceFromLog {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines,
    [Parameter(Mandatory = $true)]
    [bool]$IncludeWarnMixins
  )

  # * Map: modId -> list of evidence strings.
  $evidence = @{}

  $fromModSeverityRegex = if ($IncludeWarnMixins) { "(ERROR|WARN)" } else { "ERROR" }
  $mixinApplySeverityRegex = "(ERROR|WARN)"
  $fromModPattern = "^\[.*?\]\s+\[.*?\/" + $fromModSeverityRegex + "\]:\s+.*?\bfrom mod\s+(?<id>[a-z0-9_\-\.]+)\b"
  $mixinApplyPattern = "^\[.*?\]\s+\[.*?\/" + $mixinApplySeverityRegex + "\]:\s+Mixin apply for mod\s+(?<id>[a-z0-9_\-\.]+)\s+failed\b"

  # * Crash report lines can be unprefixed. Match only if the line indicates a failure.
  $crashReportModPattern = "^(?!\[).*(failed|Critical injection|InjectionError|Mixin transformation).*\bfrom mod\s+(?<id>[a-z0-9_\-\.]+)\b"

  # * Crash report lines often include "provided by '<modid>'" for entrypoint failures.
  $crashProvidedByPattern = "^(?!\[).*\bprovided by\s+['""](?<id>[a-z0-9_\-\.]+)['""]"

  # * Dependency patterns (seen in other Fabric logs; keep as best-effort).
  $requiresPattern1 = "^\[.*?\]\s+\[.*?\/ERROR\]:\s+Mod\s+(?<id>[a-z0-9_\-\.]+)\s+requires\b"
  $requiresPattern2 = "^\[.*?\]\s+\[.*?\/ERROR\]:\s+Could not find required mod:\s+(?<id>[a-z0-9_\-\.]+)\b"

  # * Incompatible mod list patterns from Fabric loader.
  $incompatibleDetailPattern = '(requires|required|incompatible|not compatible|depends|needs|was built for|requires version|requires minecraft|requires fabric|requires fabricloader|requires loader)'
  $modNamedErrorPattern = '^\[.*?\]\s+\[.*?/(ERROR|WARN)\]:\s+Mod\s+[''"]?.*?[''"]?\s+\((?<id>[a-z0-9_\-\.]+)\)\b(?<detail>.*)$'
  $modNamedListPattern = '^\s*-\s+Mod\s+[''"]?.*?[''"]?\s+\((?<id>[a-z0-9_\-\.]+)\)\b(?<detail>.*)$'
  $modBareErrorPattern = '^\[.*?\]\s+\[.*?/(ERROR|WARN)\]:\s+Mod\s+(?<id>[a-z0-9_\-\.]+)\b(?<detail>.*)$'

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, $mixinApplyPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $fromModPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $requiresPattern1, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $requiresPattern2, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $modNamedErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $modBareErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $modNamedListPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $detail = $m.Groups["detail"].Value
      if ($detail -match $incompatibleDetailPattern) {
        $id = $m.Groups["id"].Value.ToLowerInvariant()
        if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
        $evidence[$id].Add($line.Trim())
        continue
      }
    }

    $m = [regex]::Match($line, $crashReportModPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $crashProvidedByPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }
  }

  return $evidence
}

function Get-FabricModIdsFromJar {
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarPath
  )

  # * Reads fabric.mod.json from the jar (zip) without extracting to disk.
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = $null
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    $entry = $zip.Entries | Where-Object { $_.FullName -eq "fabric.mod.json" } | Select-Object -First 1
    if (-not $entry) { return @() }
    $sr = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8, $true)
    try {
      $jsonText = $sr.ReadToEnd()
    } finally {
      $sr.Dispose()
    }
    $obj = $jsonText | ConvertFrom-Json -ErrorAction Stop
    $ids = @{}
    if ($null -ne $obj.id -and -not [string]::IsNullOrWhiteSpace([string]$obj.id)) {
      $ids[[string]$obj.id.ToLowerInvariant()] = $true
    }
    if ($null -ne $obj.provides) {
      if ($obj.provides -is [string]) {
        $value = [string]$obj.provides
        if (-not [string]::IsNullOrWhiteSpace($value)) {
          $ids[$value.ToLowerInvariant()] = $true
        }
      } else {
        foreach ($entryId in $obj.provides) {
          $value = [string]$entryId
          if (-not [string]::IsNullOrWhiteSpace($value)) {
            $ids[$value.ToLowerInvariant()] = $true
          }
        }
      }
    }
    if ($ids.Count -eq 0) { return @() }
    return @($ids.Keys)
  } catch {
    return @()
  } finally {
    if ($zip) { $zip.Dispose() }
  }
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
  $files = Get-ChildItem -LiteralPath $DirPath -Filter "*.jar" -File -ErrorAction Stop
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

function New-DirectoryIfMissing {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [string]$DirPath
  )
  if (-not (Test-Path -LiteralPath $DirPath)) {
    if ($PSCmdlet.ShouldProcess($DirPath, "Create directory")) {
      New-Item -ItemType Directory -Path $DirPath -Force | Out-Null
    }
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
$primaryLogPath = Get-LatestTLauncherLogPath -PreferredPath $LogPath
$additionalLogPaths = @()
if (-not $SkipGameLogs -and [string]::IsNullOrWhiteSpace($LogPath)) {
  $additionalLogPaths = Get-AdditionalGameLogPaths -GameModsDir $GameModsDir
  $additionalLogPaths = Select-RecentLogPaths -Paths $additionalLogPaths -MaxAgeMinutes $LogMaxAgeMinutes
}
$resolvedLogPaths = Resolve-LogPaths -PrimaryPath $primaryLogPath -AdditionalPaths $additionalLogPaths
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

if ($compatLogsEnabled) {
  $legacyLogPath = Join-Path -Path $PSScriptRoot -ChildPath "legacy.log"
  Write-LegacyLog -EvidenceByModId $evidenceByModId -LogPath $legacyLogPath
}

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

$actions = New-Object System.Collections.Generic.List[object]

foreach ($modId in ($evidenceByModId.Keys | Sort-Object)) {
  $gameJarPaths = @()
  if ($gameIdToJars.ContainsKey($modId)) { $gameJarPaths = @($gameIdToJars[$modId]) }

  if (-not $gameJarPaths -or $gameJarPaths.Count -eq 0) {
    $actions.Add([pscustomobject]@{
        modId = $modId
        status = "unresolved_in_game_mods"
        evidence = @($evidenceByModId[$modId])
        game = @()
        storage = @()
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

    $gameResult = Move-OrDelete -SourcePath $gameJarPath -DestDir $gameLegacyVersionDir -DoDelete $deleteFromGame -IsDryRun ([bool]$DryRun)
    $storageResult = $null
    if ($storageJarPath) {
      $storageResult = Move-OrDelete -SourcePath $storageJarPath -DestDir $storageLegacyVersionDir -DoDelete $deleteFromStorage -IsDryRun ([bool]$DryRun)
    } else {
      $storageResult = ("not found in storage root for file '{0}' (modId '{1}')" -f $gameFileName, $modId)
    }

    $actions.Add([pscustomobject]@{
        modId = $modId
        status = "handled"
        evidence = @($evidenceByModId[$modId])
        game = @($gameResult)
        storage = @($storageResult)
      })
  }
}

if ($TreatNonFabricAsIncompatible -and $nonFabricJarNames -and $nonFabricJarNames.Count -gt 0) {
  foreach ($jarName in $nonFabricJarNames) {
    $gamePath = Join-Path -Path $GameModsDir -ChildPath $jarName
    $storagePath = Join-Path -Path $StorageModsDir -ChildPath $jarName

    $gameResult = $null
    if (Test-Path -LiteralPath $gamePath) {
      $gameResult = Move-OrDelete -SourcePath $gamePath -DestDir $gameLegacyVersionDir -DoDelete $deleteFromGame -IsDryRun ([bool]$DryRun)
    } else {
      $gameResult = ("not present in game mods: {0}" -f $jarName)
    }

    $storageResult = $null
    if (Test-Path -LiteralPath $storagePath) {
      $storageResult = Move-OrDelete -SourcePath $storagePath -DestDir $storageLegacyVersionDir -DoDelete $deleteFromStorage -IsDryRun ([bool]$DryRun)
    } else {
      $storageResult = ("not present in storage root: {0}" -f $jarName)
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

