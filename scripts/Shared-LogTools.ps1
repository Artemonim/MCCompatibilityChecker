# * Shared log and file helpers for MCCompatibilityChecker.

function Get-LatestTLauncherLogPath {
  param(
    [Parameter(Mandatory = $false)]
    [string]$PreferredPath,
    [Parameter(Mandatory = $false)]
    [bool]$AllowMissing = $false,
    # * If provided, ignores stale preferred logs and selects only logs written after this timestamp.
    [Parameter(Mandatory = $false)]
    [datetime]$SinceTimestamp = [datetime]::MinValue,
    # * Allowed clock skew (seconds) when applying SinceTimestamp.
    [Parameter(Mandatory = $false)]
    [int]$SinceSkewSeconds = 120
  )

  $applySince = ($SinceTimestamp -ne [datetime]::MinValue)
  $sinceCutoff = if ($applySince) { $SinceTimestamp.AddSeconds(-$SinceSkewSeconds) } else { [datetime]::MinValue }

  if (-not [string]::IsNullOrWhiteSpace($PreferredPath) -and (Test-Path -LiteralPath $PreferredPath)) {
    if (-not $applySince) {
      return $PreferredPath
    }

    $prefItem = Get-Item -LiteralPath $PreferredPath -ErrorAction SilentlyContinue
    if ($null -ne $prefItem -and $prefItem.LastWriteTime -ge $sinceCutoff) {
      return $PreferredPath
    }
  }

  $tempDir = [System.IO.Path]::GetTempPath()
  $candidates = Get-ChildItem -LiteralPath $tempDir -Filter "tl-logger*.txt" -File -ErrorAction SilentlyContinue |
    Sort-Object -Property LastWriteTime -Descending
  if ($applySince) {
    $candidates = @($candidates | Where-Object { $_.LastWriteTime -ge $sinceCutoff })
  }
  if (-not $candidates -or $candidates.Count -eq 0) {
    if ($AllowMissing) { return $null }
    if ($applySince) {
      throw ("Could not find tl-logger*.txt in temp dir newer than {0}: {1}" -f $sinceCutoff, $tempDir)
    }
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

function Get-AdditionalGameLogPath {
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
    # ! Avoid Select-Object -First which can emit PipelineStoppedException under $ErrorActionPreference='Stop'.
    $crashFiles = @(Get-ChildItem -LiteralPath $crashDir -Filter "*.txt" -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)
    $latestCrash = $null
    if ($crashFiles -and $crashFiles.Count -gt 0) {
      $latestCrash = $crashFiles[0]
    }
    if ($latestCrash) { $paths.Add($latestCrash.FullName) }
  }

  return $paths
}

function Select-RecentLogPath {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Paths,
    [Parameter(Mandatory = $true)]
    [int]$MaxAgeMinutes,
    [Parameter(Mandatory = $false)]
    [datetime]$SinceTimestamp = [datetime]::MinValue,
    [Parameter(Mandatory = $false)]
    [int]$SinceSkewSeconds = 120
  )

  if (-not $Paths -or $Paths.Count -eq 0) { return @() }
  $applyMaxAge = ($MaxAgeMinutes -gt 0)
  $applySince = ($SinceTimestamp -ne [datetime]::MinValue)
  if (-not $applyMaxAge -and -not $applySince) { return $Paths }

  $cutoff = if ($applyMaxAge) { (Get-Date).AddMinutes(-$MaxAgeMinutes) } else { [datetime]::MinValue }
  $sinceCutoff = if ($applySince) { $SinceTimestamp.AddSeconds(-$SinceSkewSeconds) } else { [datetime]::MinValue }
  $recent = New-Object System.Collections.Generic.List[string]
  foreach ($path in $Paths) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($null -eq $item) { continue }
    $lastWrite = $item.LastWriteTime
    if ($applyMaxAge -and $lastWrite -lt $cutoff) { continue }
    if ($applySince -and $lastWrite -lt $sinceCutoff) { continue }
    $recent.Add($path)
  }
  return $recent
}

function Resolve-LogPath {
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
    $hasId = ($obj -and $obj.PSObject -and ($obj.PSObject.Properties.Name -contains "id"))
    if ($hasId) {
      $idValue = [string]$obj.id
      if (-not [string]::IsNullOrWhiteSpace($idValue)) {
        $ids[$idValue.Trim().ToLowerInvariant()] = $true
      }
    }
    $hasProvides = ($obj -and $obj.PSObject -and ($obj.PSObject.Properties.Name -contains "provides"))
    if ($hasProvides -and $null -ne $obj.provides) {
      if ($obj.provides -is [string]) {
        $value = [string]$obj.provides
        if (-not [string]::IsNullOrWhiteSpace($value)) {
          $ids[$value.Trim().ToLowerInvariant()] = $true
        }
      } elseif ($obj.provides -is [System.Collections.IDictionary] -or $obj.provides -is [System.Management.Automation.PSCustomObject]) {
        # * In fabric.mod.json, "provides" can be a map of ID to version.
        foreach ($prop in $obj.provides.psobject.properties) {
          $value = [string]$prop.Name
          if (-not [string]::IsNullOrWhiteSpace($value)) {
            $ids[$value.Trim().ToLowerInvariant()] = $true
          }
        }
      } else {
        foreach ($entryId in $obj.provides) {
          $value = [string]$entryId
          if (-not [string]::IsNullOrWhiteSpace($value)) {
            $ids[$value.Trim().ToLowerInvariant()] = $true
          }
        }
      }
    }
    if ($ids.Count -eq 0) { return @() }
    # ! Use unary comma to prevent single-element unwrapping.
    return ,@($ids.Keys)
  } catch {
    return @()
  } finally {
    if ($zip) { $zip.Dispose() }
  }
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
