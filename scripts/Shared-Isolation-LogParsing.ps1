function Get-ConfiguredLogSnapshot {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$PrimaryLogPath = $LogPath
  )

  return Get-LogSnapshot -PrimaryLogPath $PrimaryLogPath `
    -GameModsDir $GameModsDir `
    -SkipGameLogs ([bool]$SkipGameLogs) `
    -LogMaxAgeMinutes $LogMaxAgeMinutes `
    -LogReadRetryCount $LogReadRetryCount `
    -LogReadRetryDelayMs $LogReadRetryDelayMs
}

function Get-LogSnapshot {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$PrimaryLogPath = "",
    [Parameter(Mandatory = $true)]
    [string]$GameModsDir,
    [Parameter(Mandatory = $true)]
    [bool]$SkipGameLogs,
    [Parameter(Mandatory = $true)]
    [int]$LogMaxAgeMinutes,
    [Parameter(Mandatory = $true)]
    [int]$LogReadRetryCount,
    [Parameter(Mandatory = $true)]
    [int]$LogReadRetryDelayMs
  )

  $resolvedPrimary = Get-LatestTLauncherLogPath -PreferredPath $PrimaryLogPath -AllowMissing $true
  $additionalLogPaths = @()
  if (-not $SkipGameLogs -and [string]::IsNullOrWhiteSpace($PrimaryLogPath)) {
    $additionalLogPaths = Get-AdditionalGameLogPaths -GameModsDir $GameModsDir
    $additionalLogPaths = Select-RecentLogPaths -Paths $additionalLogPaths -MaxAgeMinutes $LogMaxAgeMinutes
  }
  $resolvedLogPaths = Resolve-LogPaths -PrimaryPath $resolvedPrimary -AdditionalPaths $additionalLogPaths
  $resolvedLogPaths = @($resolvedLogPaths)

  $logLinesBySource = @{}
  foreach ($logPath in $resolvedLogPaths) {
    if (-not (Test-Path -LiteralPath $logPath)) { continue }
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

  return [pscustomobject]@{
    PrimaryLog = $resolvedPrimary
    Logs = $resolvedLogPaths
    Lines = $allLogLines
    LineCount = (Get-LineCountSafe -Lines $allLogLines)
  }
}

function Get-IncompatibleModIdsFromLog {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines,
    [Parameter(Mandatory = $true)]
    [bool]$IncludeWarnMixins
  )

  $ids = @{}
  $fromModSeverityRegex = if ($IncludeWarnMixins) { "(ERROR|WARN)" } else { "ERROR" }
  $mixinApplySeverityRegex = "(ERROR|WARN)"
  $fromModPattern = "^\[.*?\]\s+\[.*?\/" + $fromModSeverityRegex + "\]:\s+.*?\bfrom mod\s+(?<id>[a-z0-9_\-\.]+)\b"
  $mixinApplyPattern = "^\[.*?\]\s+\[.*?\/" + $mixinApplySeverityRegex + "\]:\s+Mixin apply for mod\s+(?<id>[a-z0-9_\-\.]+)\s+failed\b"
  $crashReportModPattern = "^(?!\[).*(failed|Critical injection|InjectionError|Mixin transformation).*\bfrom mod\s+(?<id>[a-z0-9_\-\.]+)\b"
  $crashProvidedByPattern = "^(?!\[).*\bprovided by\s+['""](?<id>[a-z0-9_\-\.]+)['""]"
  $requiresPattern1 = "^\[.*?\]\s+\[.*?\/ERROR\]:\s+Mod\s+(?<id>[a-z0-9_\-\.]+)\s+requires\b"
  $requiresPattern2 = "^\[.*?\]\s+\[.*?\/ERROR\]:\s+Could not find required mod:\s+(?<id>[a-z0-9_\-\.]+)\b"
  $incompatibleDetailPattern = '(requires|required|incompatible|not compatible|depends|needs|was built for|requires version|requires minecraft|requires fabric|requires fabricloader|requires loader)'
  $modNamedErrorPattern = '^\[.*?\]\s+\[.*?/(ERROR|WARN)\]:\s+Mod\s+[''"]?.*?[''"]?\s+\((?<id>[a-z0-9_\-\.]+)\)\b(?<detail>.*)$'
  $modNamedListPattern = '^\s*-\s+Mod\s+[''"]?.*?[''"]?\s+\((?<id>[a-z0-9_\-\.]+)\)\b(?<detail>.*)$'
  $modBareErrorPattern = '^\[.*?\]\s+\[.*?/(ERROR|WARN)\]:\s+Mod\s+(?<id>[a-z0-9_\-\.]+)\b(?<detail>.*)$'

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, $mixinApplyPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $fromModPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $requiresPattern1, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $requiresPattern2, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $modNamedErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $modBareErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $modNamedListPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $detail = $m.Groups["detail"].Value
      if ($detail -match $incompatibleDetailPattern) {
        $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
        continue
      }
    }

    $m = [regex]::Match($line, $crashReportModPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $crashProvidedByPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }
  }

  if ($ids.Count -eq 0) { return @() }
  # ! Use unary comma to prevent single-element unwrapping (avoids missing .Count on callers).
  return ,@($ids.Keys | Sort-Object)
}

function Get-FabricRequiringModIds {
  <#
  .SYNOPSIS
  Extracts mod IDs that REQUIRE missing dependencies (the mod to blame, not the missing dep).
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  $ids = @{}
  # * Pattern: "Mod 'Name' (mod-id) X.Y.Z requires version ... of dependency, which is missing!"
  # * Accepts versions like "1.4.1+1.21.7" and list-style lines like "- Mod 'Bonded' ...".
  $fabricRequiresPattern = "^\s*(?:-\s+)?Mod\s+['""]?[^'""]+['""]?\s+\((?<id>[a-z0-9_\-\.]+)\)\s+\S+\s+requires\s+"

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, $fabricRequiresPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
    }
  }

  if ($ids.Count -eq 0) { return @() }
  # ! Use unary comma to prevent single-element unwrapping (avoids missing .Count on callers).
  return ,@($ids.Keys | Sort-Object)
}

function Get-FabricMissingDependencyIds {
  <#
  .SYNOPSIS
  Extracts missing dependency mod IDs from Fabric logs/dialog text.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  $ids = @{}
  # * Pattern: "... requires version ... of libjf-base, which is missing!"
  $requiresMissingPattern = "requires\s+version\s+.+?\s+of\s+(?<id>[a-z0-9_\-\.]+),\s+which\s+is\s+missing"
  # * Pattern: "Could not find required mod: libjf-base"
  $couldNotFindPattern = "Could not find required mod:\s+(?<id>[a-z0-9_\-\.]+)\b"
  # * Pattern: "owo-lib is required to run the following mods"
  $requiredToRunPattern = "(?<id>[a-z0-9_\-\.]+)\s+is\s+required\s+to\s+run\s+the\s+following\s+mods?\b"

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, $requiresMissingPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }
    $m = [regex]::Match($line, $couldNotFindPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }
    $m = [regex]::Match($line, $requiredToRunPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }
  }

  if ($ids.Count -eq 0) { return @() }
  return ,@($ids.Keys | Sort-Object)
}

function ConvertTo-NormalizedLogLine {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Line
  )

  $text = $Line.Trim()
  $text = [regex]::Replace($text, "^\[[^\]]+\]\s+\[[^\]]+\]:\s+", "")
  $text = [regex]::Replace($text, "^\[[^\]]+\]:\s+", "")
  $text = [regex]::Replace($text, "\s+", " ")
  return $text
}

function Select-ErrorEvidenceLines {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines,
    [Parameter(Mandatory = $true)]
    [int]$MaxLines
  )

  $selected = New-Object System.Collections.Generic.List[string]
  if ($MaxLines -le 0) { return $selected }

  $pattern = "(ERROR|Exception|Caused by|Mixin apply|InjectionError|Critical injection|Crash Report|crash report|from mod|Could not find required mod|requires\b)"

  # * Collect deterministically: normalize -> unique -> sort -> take N.
  $unique = @{}
  foreach ($line in $Lines) {
    if ($line -match $pattern) {
      $norm = ConvertTo-NormalizedLogLine -Line $line
      if (-not [string]::IsNullOrWhiteSpace($norm)) {
        $unique[$norm] = $true
      }
    }
  }
  if ($unique.Count -eq 0) { return $selected }
  foreach ($norm in ($unique.Keys | Sort-Object)) {
    $selected.Add($norm)
    if ($selected.Count -ge $MaxLines) { break }
  }

  return $selected
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

function Get-ErrorSignature {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines,
    [Parameter(Mandatory = $true)]
    [int]$MaxLines,
    [Parameter(Mandatory = $true)]
    [bool]$IncludeWarnMixins
  )

  $safeLines = @($Lines)
  $parts = New-Object System.Collections.Generic.List[string]
  $modIds = @(Get-IncompatibleModIdsFromLog -Lines $safeLines -IncludeWarnMixins $IncludeWarnMixins)
  if ($modIds.Count -eq 1 -and $null -ne $modIds[0] -and ($modIds[0] -is [System.Collections.IEnumerable]) -and -not ($modIds[0] -is [string])) {
    $modIds = @($modIds[0])
  }
  $modIds = @($modIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($modIds.Count -gt 0) {
    $parts.Add(("mods: {0}" -f ($modIds -join ", ")))
  }

  $evidenceLines = @(Select-ErrorEvidenceLines -Lines $safeLines -MaxLines $MaxLines)
  if ($evidenceLines.Count -gt 0) {
    $parts.Add(("lines: {0}" -f ($evidenceLines -join " | ")))
  }

  if ($parts.Count -eq 0) { return "" }
  return ($parts -join "; ")
}

function Get-ErrorEvidenceKey {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines,
    [Parameter(Mandatory = $true)]
    [int]$MaxLines
  )

  $safeLines = @($Lines)
  $evidenceLines = @(Select-ErrorEvidenceLines -Lines $safeLines -MaxLines $MaxLines)
  if (-not $evidenceLines -or $evidenceLines.Count -eq 0) { return "" }

  $norm = @()
  foreach ($l in $evidenceLines) {
    $v = [string]$l
    if ([string]::IsNullOrWhiteSpace($v)) { continue }
    $norm += @($v.Trim())
  }
  if (-not $norm -or $norm.Count -eq 0) { return "" }
  return ($norm -join " | ")
}

function Test-SignatureChanged {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Baseline,
    [Parameter(Mandatory = $true)]
    [string]$Current,
    [Parameter(Mandatory = $false)]
    [string]$BaselineEvidenceKey = "",
    [Parameter(Mandatory = $false)]
    [string]$CurrentEvidenceKey = "",
    [Parameter(Mandatory = $false)]
    [bool]$IgnoreModsWhenEvidencePresent = $true
  )

  # * Prefer evidence-line comparison when available to avoid false positives caused by
  # * changes in Fabric's "incompatible mods" listing (dependency cascades).
  if ($IgnoreModsWhenEvidencePresent -and (-not [string]::IsNullOrWhiteSpace($BaselineEvidenceKey) -or -not [string]::IsNullOrWhiteSpace($CurrentEvidenceKey))) {
    if ([string]::IsNullOrWhiteSpace($BaselineEvidenceKey)) { return $true }
    if ([string]::IsNullOrWhiteSpace($CurrentEvidenceKey)) { return $true }
    return -not [string]::Equals($BaselineEvidenceKey, $CurrentEvidenceKey, [System.StringComparison]::OrdinalIgnoreCase)
  }

  if ([string]::IsNullOrWhiteSpace($Baseline)) {
    return (-not [string]::IsNullOrWhiteSpace($Current))
  }
  if ([string]::IsNullOrWhiteSpace($Current)) { return $true }
  return -not [string]::Equals($Baseline, $Current, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-FabricDependencyDialogInfo {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  $requiringRaw = @(Get-FabricRequiringModIds -Lines $Lines)
  $requiringArr = @($requiringRaw |
      ForEach-Object { [string]$_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object -Unique)

  $missingRaw = @(Get-FabricMissingDependencyIds -Lines $Lines)
  $missingArr = @($missingRaw |
      ForEach-Object { [string]$_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object -Unique)

  return [pscustomobject]@{
    RequiringModIds = @($requiringArr)
    MissingDepIds = @($missingArr)
    HasMissingDeps = ($missingArr.Count -gt 0)
  }
}

function Test-DependencyDialogBlock {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Context,
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  if (-not [bool]$RespectDependencyDialogsInBaseline) { return $false }

  $info = Get-FabricDependencyDialogInfo -Lines $Lines
  if (-not $info.HasMissingDeps) { return $false }

  $reqLabel = if ($info.RequiringModIds.Count -gt 0) { $info.RequiringModIds -join ", " } else { "<none>" }
  $missLabel = if ($info.MissingDepIds.Count -gt 0) { $info.MissingDepIds -join ", " } else { "<none>" }
  Write-Host ("Dependency dialog detected during {0}. Missing deps: {1}; Requiring mods: {2}" -f $Context, $missLabel, $reqLabel) -ForegroundColor Yellow

  $script:blockedByDependency = $true
  $script:blockedDependencyMissing = @($info.MissingDepIds)
  $script:blockedDependencyRequiring = @($info.RequiringModIds)
  $script:blockedDependencyContext = $Context
  return $true
}
