function ConvertTo-McccLegacyLogPathValue {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$PathValue = ""
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
  $normalized = [string]$PathValue
  $normalized = $normalized.Trim()
  while ($normalized.Length -ge 2 -and (
      ($normalized.StartsWith("'") -and $normalized.EndsWith("'")) -or
      ($normalized.StartsWith('"') -and $normalized.EndsWith('"'))
    )) {
    $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
  }
  return $normalized
}

function Get-McccLegacyLogMoveInfo {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$Line
  )

  if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
  $text = [string]$Line

  $patterns = @(
    [pscustomobject]@{
      Kind    = "storage"
      Pattern = "Moved culprit to storage legacy:\s*(?<path>.+)$"
    },
    [pscustomobject]@{
      Kind    = "game"
      Pattern = "Moved culprit to game legacy:\s*(?<path>.+)$"
    },
    [pscustomobject]@{
      Kind    = "game"
      Pattern = "Moved culprit to game legacy fallback:\s*(?<path>.+)$"
    }
  )

  foreach ($entry in @($patterns)) {
    $m = [regex]::Match($text, [string]$entry.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { continue }
    $sourcePath = ConvertTo-McccLegacyLogPathValue -PathValue ([string]$m.Groups["path"].Value)
    if ([string]::IsNullOrWhiteSpace($sourcePath)) { continue }
    return [pscustomobject]@{
      Kind       = [string]$entry.Kind
      SourcePath = $sourcePath
    }
  }

  return $null
}

function Resolve-McccLegacyLogSinceTimestamp {
  param(
    [Parameter(Mandatory = $false)]
    [datetime]$SinceTimestamp = [datetime]::MinValue
  )

  if ($SinceTimestamp -eq [datetime]::MinValue) {
    return [datetime]::MinValue
  }

  return [datetime]::ParseExact(
    $SinceTimestamp.ToString("yyyy-MM-dd HH:mm:ss"),
    "yyyy-MM-dd HH:mm:ss",
    [System.Globalization.CultureInfo]::InvariantCulture
  )
}

function Get-McccLegacyLogCulpritMoves {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$LogLines = @(),
    [Parameter(Mandatory = $false)]
    [datetime]$SinceTimestamp = [datetime]::MinValue,
    [Parameter(Mandatory = $true)]
    [string]$GameModsDir,
    [Parameter(Mandatory = $true)]
    [string]$StorageModsDir
  )

  $timestampPattern = '^\s*\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s*$'
  $currentTimestamp = [datetime]::MinValue
  $effectiveSinceTimestamp = Resolve-McccLegacyLogSinceTimestamp -SinceTimestamp $SinceTimestamp
  $movesByJar = @{}

  foreach ($line in @($LogLines)) {
    $textLine = [string]$line
    if ($textLine -match $timestampPattern) {
      try {
        $currentTimestamp = [datetime]::ParseExact($textLine.Trim(), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
      } catch {
        $currentTimestamp = [datetime]::MinValue
      }
      continue
    }

    if ([string]::IsNullOrWhiteSpace($textLine)) { continue }

    $moveInfo = Get-McccLegacyLogMoveInfo -Line $textLine
    if ($null -eq $moveInfo) { continue }

    if ($effectiveSinceTimestamp -ne [datetime]::MinValue) {
      if ($currentTimestamp -eq [datetime]::MinValue) { continue }
      if ($currentTimestamp -lt $effectiveSinceTimestamp) { continue }
    }

    $sourcePath = [string]$moveInfo.SourcePath
    $jarName = [System.IO.Path]::GetFileName($sourcePath)
    if ([string]::IsNullOrWhiteSpace($jarName) -or (-not $jarName.EndsWith(".jar", [System.StringComparison]::OrdinalIgnoreCase))) {
      continue
    }

    $jarKey = $jarName.ToLowerInvariant()
    if (-not $movesByJar.ContainsKey($jarKey)) {
      $movesByJar[$jarKey] = [pscustomobject]@{
        JarName                 = $jarName
        GameModsDir             = $gameModsDir
        StorageModsDir          = $storageModsDir
        StorageLegacyPath       = ""
        GameLegacyPath          = ""
        Minecraft               = "unknown"
        KeepCulpritInGameLegacy = $true
        CrashEvidenceKey        = ""
        Stage                   = "interrupt-auto-restore"
      }
    }

    if ([string]$moveInfo.Kind -eq "storage") {
      $movesByJar[$jarKey].StorageLegacyPath = $sourcePath
    } elseif ([string]$moveInfo.Kind -eq "game") {
      $movesByJar[$jarKey].GameLegacyPath = $sourcePath
    }
  }

  return [pscustomobject]@{
    EffectiveSinceTimestamp = $effectiveSinceTimestamp
    CulpritMoves            = @($movesByJar.Values | Sort-Object -Property JarName)
  }
}
