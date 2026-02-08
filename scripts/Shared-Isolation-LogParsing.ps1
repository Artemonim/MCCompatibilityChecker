function Get-ConfiguredLogSnapshot {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$PrimaryLogPath = $LogPath,
    [Parameter(Mandatory = $false)]
    [datetime]$SinceTimestamp = [datetime]::MinValue,
    [Parameter(Mandatory = $false)]
    [int]$SinceTimestampSkewSeconds = 120,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $gameModsDir = $GameModsDir
  $skipGameLogs = [bool]$SkipGameLogs
  $logMaxAgeMinutes = $LogMaxAgeMinutes
  $logReadRetryCount = $LogReadRetryCount
  $logReadRetryDelayMs = $LogReadRetryDelayMs

  if ($null -ne $Context) {
    if (-not $PSBoundParameters.ContainsKey("PrimaryLogPath")) {
      $contextLogPath = ""
      if ($null -ne $Context.Log -and $Context.Log.PSObject.Properties.Match("LogPath").Count -gt 0) {
        $contextLogPath = [string]$Context.Log.LogPath
      }
      if ([string]::IsNullOrWhiteSpace($contextLogPath) -and $null -ne $Context.Paths -and $Context.Paths.PSObject.Properties.Match("LogPath").Count -gt 0) {
        $contextLogPath = [string]$Context.Paths.LogPath
      }
      if (-not [string]::IsNullOrWhiteSpace($contextLogPath)) {
        $PrimaryLogPath = $contextLogPath
      }
    }
    if ($null -ne $Context.Paths -and $Context.Paths.PSObject.Properties.Match("GameModsDir").Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$Context.Paths.GameModsDir)) {
      $gameModsDir = [string]$Context.Paths.GameModsDir
    }
    if ($null -ne $Context.Log) {
      if ($Context.Log.PSObject.Properties.Match("SkipGameLogs").Count -gt 0) {
        $skipGameLogs = [bool]$Context.Log.SkipGameLogs
      }
      if ($Context.Log.PSObject.Properties.Match("LogMaxAgeMinutes").Count -gt 0) {
        $logMaxAgeMinutes = [int]$Context.Log.LogMaxAgeMinutes
      }
      if ($Context.Log.PSObject.Properties.Match("LogReadRetryCount").Count -gt 0) {
        $logReadRetryCount = [int]$Context.Log.LogReadRetryCount
      }
      if ($Context.Log.PSObject.Properties.Match("LogReadRetryDelayMs").Count -gt 0) {
        $logReadRetryDelayMs = [int]$Context.Log.LogReadRetryDelayMs
      }
      if (-not $PSBoundParameters.ContainsKey("SinceTimestampSkewSeconds") -and $Context.Log.PSObject.Properties.Match("LogSinceSkewSeconds").Count -gt 0) {
        $SinceTimestampSkewSeconds = [int]$Context.Log.LogSinceSkewSeconds
      }
    }
  }

  return Get-LogSnapshot -PrimaryLogPath $PrimaryLogPath `
    -GameModsDir $gameModsDir `
    -SkipGameLogs $skipGameLogs `
    -LogMaxAgeMinutes $logMaxAgeMinutes `
    -LogReadRetryCount $logReadRetryCount `
    -LogReadRetryDelayMs $logReadRetryDelayMs `
    -SinceTimestamp $SinceTimestamp `
    -SinceTimestampSkewSeconds $SinceTimestampSkewSeconds
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
    [int]$LogReadRetryDelayMs,
    [Parameter(Mandatory = $false)]
    [datetime]$SinceTimestamp = [datetime]::MinValue,
    [Parameter(Mandatory = $false)]
    [int]$SinceTimestampSkewSeconds = 120
  )

  $resolvedPrimary = Get-LatestTLauncherLogPath -PreferredPath $PrimaryLogPath -AllowMissing $true `
    -SinceTimestamp $SinceTimestamp -SinceSkewSeconds $SinceTimestampSkewSeconds
  $primaryLastWrite = [datetime]::MinValue
  if (-not [string]::IsNullOrWhiteSpace($resolvedPrimary) -and (Test-Path -LiteralPath $resolvedPrimary)) {
    $primaryItem = Get-Item -LiteralPath $resolvedPrimary -ErrorAction SilentlyContinue
    if ($null -ne $primaryItem) {
      $primaryLastWrite = $primaryItem.LastWriteTime
    }
  }
  $effectiveSince = $SinceTimestamp
  if ($effectiveSince -eq [datetime]::MinValue -and $primaryLastWrite -ne [datetime]::MinValue) {
    $effectiveSince = $primaryLastWrite
  }
  $additionalLogPaths = @()
  if (-not $SkipGameLogs -and [string]::IsNullOrWhiteSpace($PrimaryLogPath)) {
    $additionalLogPaths = Get-AdditionalGameLogPath -GameModsDir $GameModsDir
    $additionalLogPaths = Select-RecentLogPath -Paths $additionalLogPaths -MaxAgeMinutes $LogMaxAgeMinutes `
      -SinceTimestamp $effectiveSince -SinceSkewSeconds $SinceTimestampSkewSeconds
  }
  $resolvedLogPaths = Resolve-LogPath -PrimaryPath $resolvedPrimary -AdditionalPaths $additionalLogPaths
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

function Get-IncompatibleModPatternSet {
  param(
    [Parameter(Mandatory = $true)]
    [bool]$IncludeWarnMixins
  )

  $fromModSeverityRegex = if ($IncludeWarnMixins) { "(ERROR|WARN)" } else { "ERROR" }
  $mixinApplySeverityRegex = "(ERROR|WARN)"
  $fromModPattern = "^\[.*?\]\s+\[.*?\/" + $fromModSeverityRegex + "\]:\s+.*?\bfrom mod\s+(?<id>[a-z0-9_\-\.]+)\b"
  $mixinApplyPattern = "^\[.*?\]\s+\[.*?\/" + $mixinApplySeverityRegex + "\]:\s+Mixin apply for mod\s+(?<id>[a-z0-9_\-\.]+)\s+failed\b"
  $crashReportModPattern = "^(?!\[).*(failed|Critical injection|InjectionError|Mixin transformation).*\bfrom mod\s+(?<id>[a-z0-9_\-\.]+)\b"
  $crashProvidedByPattern = "^(?!\[).*\bprovided by\s+['""](?<id>[a-z0-9_\-\.]+)['""]"
  $requiresPattern1 = "^\[.*?\]\s+\[.*?\/ERROR\]:\s+Mod\s+(?<id>[a-z0-9_\-\.]+)\s+requires\b"
  $requiresPattern2 = "^\[.*?\]\s+\[.*?\/ERROR\]:\s+Could not find required mod:\s+(?<id>[a-z0-9_\-\.]+)\b"
  $requiresPattern3 = "^\[.*?\]\s+\[.*?\/ERROR\]:\s+Mod\s+['""]?.*?['""]?\s+\((?<id>[a-z0-9_\-\.]+)\)\s+\S+\s+requires\b"
  $fabricRemovePattern = "^\s*(?:[-*•]\s+)?Remove\s+mod\b.*?\((?<id>[a-z0-9_\-\.]+)\)(?=\s|$|[.,!])"
  $fabricReplacePattern = "^\s*(?:[-*•]\s+)?Replace\s+mod\b.*?\((?<id>[a-z0-9_\-\.]+)\)(?=\s|$|[.,!])"
  $incompatibleDetailPattern = '(requires|required|incompatible|not compatible|depends|needs|was built for|requires version|requires minecraft|requires fabric|requires fabricloader|requires loader)'
  $modNamedErrorPattern = '^\[.*?\]\s+\[.*?/(ERROR|WARN)\]:\s+Mod\s+[''"]?.*?[''"]?\s+\((?<id>[a-z0-9_\-\.]+)\)(?<detail>\s+.*)$'
  $modNamedListPattern = '^\s*(?:[-*•]\s+)?Mod\s+[''"]?.*?[''"]?\s+\((?<id>[a-z0-9_\-\.]+)\)(?<detail>\s+.*)$'
  $modBareErrorPattern = '^\[.*?\]\s+\[.*?/(ERROR|WARN)\]:\s+Mod\s+(?<id>[a-z0-9_\-\.]+)\b(?<detail>.*)$'

  return [pscustomobject]@{
    FromModPattern = $fromModPattern
    MixinApplyPattern = $mixinApplyPattern
    CrashReportModPattern = $crashReportModPattern
    CrashProvidedByPattern = $crashProvidedByPattern
    RequiresPattern1 = $requiresPattern1
    RequiresPattern2 = $requiresPattern2
    RequiresPattern3 = $requiresPattern3
    FabricRemovePattern = $fabricRemovePattern
    FabricReplacePattern = $fabricReplacePattern
    IncompatibleDetailPattern = $incompatibleDetailPattern
    ModNamedErrorPattern = $modNamedErrorPattern
    ModNamedListPattern = $modNamedListPattern
    ModBareErrorPattern = $modBareErrorPattern
  }
}

function Get-FabricFixCandidateModIdList {
  <#
  .SYNOPSIS
  Extracts candidate mod IDs from Fabric resolver "Fix:" lines.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$Line
  )

  if ([string]::IsNullOrWhiteSpace($Line)) { return @() }
  if ($Line -notmatch "(?i)\bFix:\s+add\s+\[") { return @() }

  $ids = @{}
  $regexMatches = [regex]::Matches($Line, "\[(?<id>[a-z0-9_\-\.]+)\s+[^\]]+\]", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  foreach ($match in $regexMatches) {
    if (-not $match.Success) { continue }
    $id = [string]$match.Groups["id"].Value
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $ids[$id.ToLowerInvariant()] = $true
  }

  if ($ids.Count -eq 0) { return @() }
  return @($ids.Keys | Sort-Object)
}

function Get-IncompatibleModIdsFromLog {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines,
    [Parameter(Mandatory = $true)]
    [bool]$IncludeWarnMixins
  )

  $ids = @{}
  $patterns = Get-IncompatibleModPatternSet -IncludeWarnMixins $IncludeWarnMixins

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, $patterns.MixinApplyPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $patterns.FromModPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $patterns.RequiresPattern1, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $patterns.RequiresPattern2, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $patterns.RequiresPattern3, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $patterns.FabricRemovePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $patterns.FabricReplacePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $patterns.ModNamedErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $detail = $m.Groups["detail"].Value
      if ($detail -match $patterns.IncompatibleDetailPattern) {
        $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
        continue
      }
    }

    $m = [regex]::Match($line, $patterns.ModBareErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $detail = $m.Groups["detail"].Value
      if ($detail -match $patterns.IncompatibleDetailPattern) {
        $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
        continue
      }
    }

    $m = [regex]::Match($line, $patterns.ModNamedListPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $detail = $m.Groups["detail"].Value
      if ($detail -match $patterns.IncompatibleDetailPattern) {
        $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
        continue
      }
    }

    $m = [regex]::Match($line, $patterns.CrashReportModPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $m = [regex]::Match($line, $patterns.CrashProvidedByPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $ids[$m.Groups["id"].Value.ToLowerInvariant()] = $true
      continue
    }

    $fixIds = @(Get-FabricFixCandidateModIdList -Line ([string]$line))
    if ($fixIds.Count -gt 0) {
      foreach ($fixId in $fixIds) {
        $ids[[string]$fixId] = $true
      }
      continue
    }
  }

  if ($ids.Count -eq 0) { return @() }
  return @($ids.Keys | Sort-Object)
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
  $patterns = Get-IncompatibleModPatternSet -IncludeWarnMixins $IncludeWarnMixins

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, $patterns.MixinApplyPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $patterns.FromModPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $patterns.RequiresPattern1, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $patterns.RequiresPattern2, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $patterns.RequiresPattern3, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $patterns.FabricRemovePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $patterns.FabricReplacePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $patterns.ModNamedErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      $detail = $m.Groups["detail"].Value
      if ($detail -match $patterns.IncompatibleDetailPattern) {
        if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
        $evidence[$id].Add($line.Trim())
        continue
      }
    }

    $m = [regex]::Match($line, $patterns.ModBareErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      $detail = $m.Groups["detail"].Value
      if ($detail -match $patterns.IncompatibleDetailPattern) {
        if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
        $evidence[$id].Add($line.Trim())
        continue
      }
    }

    $m = [regex]::Match($line, $patterns.ModNamedListPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $detail = $m.Groups["detail"].Value
      if ($detail -match $patterns.IncompatibleDetailPattern) {
        $id = $m.Groups["id"].Value.ToLowerInvariant()
        if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
        $evidence[$id].Add($line.Trim())
        continue
      }
    }

    $m = [regex]::Match($line, $patterns.CrashReportModPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $m = [regex]::Match($line, $patterns.CrashProvidedByPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
      $id = $m.Groups["id"].Value.ToLowerInvariant()
      if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
      $evidence[$id].Add($line.Trim())
      continue
    }

    $fixIds = @(Get-FabricFixCandidateModIdList -Line ([string]$line))
    if ($fixIds.Count -gt 0) {
      foreach ($fixId in $fixIds) {
        $id = [string]$fixId
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if (-not $evidence.ContainsKey($id)) { $evidence[$id] = New-Object System.Collections.Generic.List[string] }
        $evidence[$id].Add($line.Trim())
      }
      continue
    }
  }

  return $evidence
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

function Get-FabricRequiringModId {
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
  return @($ids.Keys | Sort-Object)
}

function Get-FabricMissingDependencyId {
  <#
  .SYNOPSIS
  Extracts missing dependency mod IDs from Fabric logs/dialog text.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  $ids = @{}
  # * Pattern: "... requires any version of modmenu, which is missing!"
  # * Pattern: "... requires version 3.11.0 or later of resourcefullib, which is missing!"
  # * Pattern: "... requires version 1.21.1 of 'Minecraft' (minecraft), which is missing!"
  $requiresMissingPattern = "requires\s+.+?\s+of\s+(?:['""][^'""]+['""]\s+)?\(?\s*(?<id>[a-z0-9_\-\.]+)\s*\)?,?\s+which\s+is\s+missing"
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
  return @($ids.Keys | Sort-Object)
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

function Select-ErrorEvidenceLine {
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

  $evidenceLines = @(Select-ErrorEvidenceLine -Lines $safeLines -MaxLines $MaxLines)
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
  $evidenceLines = @(Select-ErrorEvidenceLine -Lines $safeLines -MaxLines $MaxLines)
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

  $requiringRaw = @(Get-FabricRequiringModId -Lines $Lines)
  $requiringArr = @($requiringRaw |
      ForEach-Object { [string]$_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object -Unique)

  $missingRaw = @(Get-FabricMissingDependencyId -Lines $Lines)
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
    [string[]]$Lines,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$StateContext = $null
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
  if ($null -ne $StateContext -and $null -ne $StateContext.State) {
    $StateContext.State.BlockedByDependency = $true
    $StateContext.State.BlockedDependencyMissing = @($info.MissingDepIds)
    $StateContext.State.BlockedDependencyRequiring = @($info.RequiringModIds)
    $StateContext.State.BlockedDependencyContext = $Context
  }
  return $true
}

# ────────────────────────────────────────────────────────────────────────────
# * Mixin error parsing.
# ────────────────────────────────────────────────────────────────────────────

function Get-MixinErrorsFromLog {
  <#
  .SYNOPSIS
  Parses Fabric Mixin errors from crash log lines.
  Returns structured objects with source mod ID, target class, and the error line.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  $results = New-Object System.Collections.Generic.List[pscustomobject]
  $pattern = '@Mixin target\s+(?<targetClass>\S+)\s+was not found\s+(?<mixinJson>\S+?):(?<mixinClass>\S+)\s+from mod\s+(?<sourceModId>[a-z0-9_\-\.]+)'
  $seen = @{}

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { continue }
    $sourceModId = $m.Groups["sourceModId"].Value.ToLowerInvariant()
    $targetClass = $m.Groups["targetClass"].Value
    $key = "{0}|{1}" -f $sourceModId, $targetClass
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $results.Add([pscustomobject]@{
        SourceModId = $sourceModId
        TargetClass = $targetClass
        MixinJson   = $m.Groups["mixinJson"].Value
        MixinClass  = $m.Groups["mixinClass"].Value
        ErrorLine   = $m.Value
      })
  }

  return ,$results
}

function Get-MixinApplyErrorsFromLog {
  <#
  .SYNOPSIS
  Parses critical "Mixin apply for mod ... failed" errors from crash log lines.
  Returns structured objects with source mod ID, target class, and mixin config.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  $results = New-Object System.Collections.Generic.List[pscustomobject]
  $patternWithTarget = 'Mixin apply for mod\s+(?<sourceModId>[a-z0-9_\-\.]+)\s+failed\s+(?<mixinRef>\S+)\s+from mod\s+(?<fromModId>[a-z0-9_\-\.]+)\s+->\s+(?<targetClass>\S+):'
  $patternFallback = 'Mixin apply for mod\s+(?<sourceModId>[a-z0-9_\-\.]+)\s+failed\s+(?<mixinRef>\S+)'
  $seen = @{}

  foreach ($line in $Lines) {
    $m = [regex]::Match($line, $patternWithTarget, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) {
      $m = [regex]::Match($line, $patternFallback, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    if (-not $m.Success) { continue }

    $sourceModId = $m.Groups["sourceModId"].Value.ToLowerInvariant()
    $mixinRef = [string]$m.Groups["mixinRef"].Value
    $targetClass = ""
    if ($m.Groups["targetClass"].Success) {
      $targetClass = [string]$m.Groups["targetClass"].Value
    }

    $mixinJson = $mixinRef
    $mixinClass = ""
    $splitIndex = $mixinRef.IndexOf(":")
    if ($splitIndex -ge 0) {
      $mixinJson = $mixinRef.Substring(0, $splitIndex)
      if ($splitIndex + 1 -lt $mixinRef.Length) {
        $mixinClass = $mixinRef.Substring($splitIndex + 1)
      }
    }

    $key = "{0}|{1}|{2}" -f $sourceModId, $targetClass, $mixinRef.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true

    $results.Add([pscustomobject]@{
        SourceModId = $sourceModId
        TargetClass = $targetClass
        MixinJson   = $mixinJson
        MixinClass  = $mixinClass
        ErrorLine   = $m.Value
      })
  }

  return ,$results
}

function Resolve-ModIdFromClassName {
  <#
  .SYNOPSIS
  Heuristically resolves a mod ID from a fully-qualified Java class name by matching
  class-name segments against known mod IDs from the dependency map.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$ClassName,
    [Parameter(Mandatory = $true)]
    [hashtable]$KnownModIds
  )

  # * Split com.author.modname.package.Class into segments and check each.
  $segments = $ClassName -split "\."
  foreach ($seg in $segments) {
    $key = $seg.ToLowerInvariant()
    if ($KnownModIds.ContainsKey($key)) {
      return $key
    }
  }

  # * Fallback: try underscore-joined pairs (e.g., "item_borders").
  for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
    $pair = ("{0}_{1}" -f $segments[$i], $segments[$i + 1]).ToLowerInvariant()
    if ($KnownModIds.ContainsKey($pair)) {
      return $pair
    }
  }

  return $null
}
