function Get-LatestCompatReportPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ReportDir,
    [Parameter(Mandatory = $false)]
    [datetime]$SinceTimestamp = [datetime]::MinValue,
    [Parameter(Mandatory = $false)]
    [int]$SinceSkewSeconds = 5
  )

  if (-not (Test-Path -LiteralPath $ReportDir)) { return "" }
  $reports = @(Get-ChildItem -LiteralPath $ReportDir -Filter "compat-report-*.json" -File -ErrorAction SilentlyContinue |
      Sort-Object -Property LastWriteTime -Descending)
  if ($reports.Count -eq 0) { return "" }
  if ($SinceTimestamp -eq [datetime]::MinValue) {
    return [string]$reports[0].FullName
  }

  $threshold = $SinceTimestamp.AddSeconds(-1 * [math]::Abs($SinceSkewSeconds))
  $freshReports = @($reports | Where-Object { $_.LastWriteTime -ge $threshold })
  if ($freshReports.Count -eq 0) { return "" }
  return [string]$freshReports[0].FullName
}

function ConvertTo-CompatActionPath {
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

function Get-CompatActionSourcePath {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$ActionText = ""
  )

  if ([string]::IsNullOrWhiteSpace($ActionText)) { return "" }
  $match = [regex]::Match(
    [string]$ActionText,
    '^\s*(?:DRYRUN\s+)?(?:moved|deleted):\s+(?<source>.+?)(?:\s+->\s+.+)?\s*$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  if (-not $match.Success) { return "" }
  return ConvertTo-CompatActionPath -PathValue ([string]$match.Groups["source"].Value)
}

function Get-CompatActionLegacyPath {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$ActionText = "",
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$JarName = ""
  )

  if ([string]::IsNullOrWhiteSpace($ActionText)) { return "" }
  $match = [regex]::Match(
    [string]$ActionText,
    '^\s*(?:DRYRUN\s+)?moved:\s+(?<source>.+?)\s+->\s+(?<dest>.+?)\s*$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  if (-not $match.Success) { return "" }

  $destination = ConvertTo-CompatActionPath -PathValue ([string]$match.Groups["dest"].Value)
  if ([string]::IsNullOrWhiteSpace($destination)) { return "" }
  if ($destination -match '(?i)\.jar$') { return $destination }

  $effectiveJarName = $JarName
  if ([string]::IsNullOrWhiteSpace($effectiveJarName)) {
    $sourcePath = ConvertTo-CompatActionPath -PathValue ([string]$match.Groups["source"].Value)
    if (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
      $effectiveJarName = [System.IO.Path]::GetFileName($sourcePath)
    }
  }
  if ([string]::IsNullOrWhiteSpace($effectiveJarName)) { return "" }

  return Join-Path -Path $destination -ChildPath $effectiveJarName
}

function Get-CompatHandledCulpritMove {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CompatReportPath,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$GameModsDir = "",
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$StorageModsDir = "",
    [Parameter(Mandatory = $false)]
    [string]$DefaultStage = "compatibility-cleanup"
  )

  if ([string]::IsNullOrWhiteSpace($CompatReportPath) -or (-not (Test-Path -LiteralPath $CompatReportPath))) {
    return @()
  }

  $report = $null
  try {
    $raw = Get-Content -LiteralPath $CompatReportPath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $report = $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return @()
  }
  if ($null -eq $report) { return @() }

  $minecraft = if ($report | Get-Member -Name "minecraft" -MemberType NoteProperty, Property) { [string]$report.minecraft } else { "" }
  if ([string]::IsNullOrWhiteSpace($minecraft)) { $minecraft = "unknown" }

  $keepInGameLegacy = $false
  if ($report | Get-Member -Name "effectiveDeleteFromGameMods" -MemberType NoteProperty, Property) {
    $keepInGameLegacy = -not [bool]$report.effectiveDeleteFromGameMods
  } elseif ($report | Get-Member -Name "gameLegacy" -MemberType NoteProperty, Property) {
    $keepInGameLegacy = [bool]$report.gameLegacy
  }

  if (-not ($report | Get-Member -Name "items" -MemberType NoteProperty, Property)) {
    return @()
  }

  $moves = New-Object System.Collections.Generic.List[pscustomobject]
  $seenJarKeys = @{}
  foreach ($item in @($report.items)) {
    if ($null -eq $item) { continue }

    $status = if ($item | Get-Member -Name "status" -MemberType NoteProperty, Property) { [string]$item.status } else { "" }
    if ($status -notin @("handled", "handled_non_fabric_by_filename")) { continue }

    $jarName = ""
    if ($item | Get-Member -Name "jar" -MemberType NoteProperty, Property) {
      $jarName = [string]$item.jar
    }
    if ([string]::IsNullOrWhiteSpace($jarName)) {
      foreach ($actionProp in @("game", "storage")) {
        if (-not ($item | Get-Member -Name $actionProp -MemberType NoteProperty, Property)) { continue }
        foreach ($actionText in @($item.$actionProp)) {
          $sourcePath = Get-CompatActionSourcePath -ActionText ([string]$actionText)
          if ([string]::IsNullOrWhiteSpace($sourcePath)) { continue }
          $jarName = [System.IO.Path]::GetFileName($sourcePath)
          if (-not [string]::IsNullOrWhiteSpace($jarName)) { break }
        }
        if (-not [string]::IsNullOrWhiteSpace($jarName)) { break }
      }
    }
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
    $jarName = [System.IO.Path]::GetFileName($jarName)
    if ([string]::IsNullOrWhiteSpace($jarName) -or (-not $jarName.EndsWith(".jar", [System.StringComparison]::OrdinalIgnoreCase))) {
      continue
    }

    $jarKey = $jarName.ToLowerInvariant()
    if ($seenJarKeys.ContainsKey($jarKey)) { continue }
    $seenJarKeys[$jarKey] = $true

    $gameLegacyPath = ""
    if ($item | Get-Member -Name "game" -MemberType NoteProperty, Property) {
      foreach ($actionText in @($item.game)) {
        $candidatePath = Get-CompatActionLegacyPath -ActionText ([string]$actionText) -JarName $jarName
        if (-not [string]::IsNullOrWhiteSpace($candidatePath)) {
          $gameLegacyPath = $candidatePath
          break
        }
      }
    }

    $storageLegacyPath = ""
    if ($item | Get-Member -Name "storage" -MemberType NoteProperty, Property) {
      foreach ($actionText in @($item.storage)) {
        $candidatePath = Get-CompatActionLegacyPath -ActionText ([string]$actionText) -JarName $jarName
        if (-not [string]::IsNullOrWhiteSpace($candidatePath)) {
          $storageLegacyPath = $candidatePath
          break
        }
      }
    }

    $evidenceKey = ""
    if ($item | Get-Member -Name "evidence" -MemberType NoteProperty, Property) {
      foreach ($line in @($item.evidence)) {
        $lineValue = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($lineValue)) {
          $evidenceKey = $lineValue
          break
        }
      }
    }

    $tier = if ($item | Get-Member -Name "dependencyTier" -MemberType NoteProperty, Property) { [int]$item.dependencyTier } else { 0 }
    $dependentMods = if ($item | Get-Member -Name "dependentMods" -MemberType NoteProperty, Property) { [int]$item.dependentMods } else { -1 }
    $dependentKnown = if ($item | Get-Member -Name "dependentModsKnown" -MemberType NoteProperty, Property) { [bool]$item.dependentModsKnown } else { $false }
    $priorityDecision = if ($item | Get-Member -Name "priorityDecision" -MemberType NoteProperty, Property) { [string]$item.priorityDecision } else { "" }

    $moves.Add([pscustomobject]@{
        JarName                = $jarName
        GameModsDir            = $GameModsDir
        StorageModsDir         = $StorageModsDir
        StorageLegacyPath      = $storageLegacyPath
        GameLegacyPath         = $gameLegacyPath
        Minecraft              = $minecraft
        KeepCulpritInGameLegacy = [bool]$keepInGameLegacy
        CrashEvidenceKey       = $evidenceKey
        DependencyTier         = [int]$tier
        DependentModCount      = [int]$dependentMods
        DependentModCountKnown = [bool]$dependentKnown
        PriorityDecision       = $priorityDecision
        Stage                  = $DefaultStage
      }) | Out-Null
  }

  return @($moves.ToArray())
}

function Write-SessionReport {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$CulpritHistoryByJar,
    [Parameter(Mandatory = $true)]
    [hashtable]$CulpritCurrentByJar,
    [Parameter(Mandatory = $false)]
    [string]$CompatReportPath = "",
    [Parameter(Mandatory = $false)]
    [datetime]$SessionStartTime = [datetime]::MinValue,
    [Parameter(Mandatory = $false)]
    [hashtable]$RecoveredJarNames = @{},
    [Parameter(Mandatory = $false)]
    [array]$MixinConflicts = @()
  )

  Write-Host ""
  Write-Host "Summary" -ForegroundColor Cyan
  $endTime = Get-Date
  Write-Host ("End time: {0}" -f $endTime.ToString("yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
  if ($SessionStartTime -ne [datetime]::MinValue) {
    $elapsed = $endTime - $SessionStartTime
    $parts = @()
    if ($elapsed.Hours -gt 0) { $parts += ("{0}h" -f $elapsed.Hours) }
    if ($elapsed.Minutes -gt 0) { $parts += ("{0}m" -f $elapsed.Minutes) }
    $parts += ("{0}s" -f $elapsed.Seconds)
    Write-Host ("Elapsed: {0}" -f ($parts -join " ")) -ForegroundColor Gray
  }
  if (-not [string]::IsNullOrWhiteSpace($CompatReportPath)) {
    Write-Host ("Compatibility report: {0}" -f $CompatReportPath) -ForegroundColor Gray
  } elseif ($SessionStartTime -ne [datetime]::MinValue) {
    Write-Host "Compatibility report was not generated in this session." -ForegroundColor Gray
  }

  $compatPriorityChoices = @()
  $compatReportFresh = $true
  if (-not [string]::IsNullOrWhiteSpace($CompatReportPath) -and (Test-Path -LiteralPath $CompatReportPath) -and $SessionStartTime -ne [datetime]::MinValue) {
    try {
      $compatInfo = Get-Item -LiteralPath $CompatReportPath -ErrorAction Stop
      if ($compatInfo.LastWriteTime -lt $SessionStartTime.AddSeconds(-5)) {
        $compatReportFresh = $false
      }
    } catch {
      $compatReportFresh = $false
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($CompatReportPath) -and (Test-Path -LiteralPath $CompatReportPath) -and $compatReportFresh) {
    try {
      $compatRaw = Get-Content -LiteralPath $CompatReportPath -Raw -ErrorAction Stop
      if (-not [string]::IsNullOrWhiteSpace($compatRaw)) {
        $compatObj = $compatRaw | ConvertFrom-Json -ErrorAction Stop
        $priorityApplied = $false
        if ($compatObj | Get-Member -Name "dependencyPriorityApplied" -MemberType NoteProperty, Property) {
          $priorityApplied = [bool]$compatObj.dependencyPriorityApplied
        }
        if ($priorityApplied -and ($compatObj | Get-Member -Name "items" -MemberType NoteProperty, Property)) {
          foreach ($item in @($compatObj.items)) {
            if ($null -eq $item) { continue }
            $status = if ($item | Get-Member -Name "status" -MemberType NoteProperty, Property) { [string]$item.status } else { "" }
            if ($status -ne "handled" -and $status -ne "unresolved_in_game_mods") { continue }
            $modId = if ($item | Get-Member -Name "modId" -MemberType NoteProperty, Property) { [string]$item.modId } else { "" }
            if ([string]::IsNullOrWhiteSpace($modId)) { continue }
            $decision = if ($item | Get-Member -Name "priorityDecision" -MemberType NoteProperty, Property) { [string]$item.priorityDecision } else { "" }
            $tier = if ($item | Get-Member -Name "dependencyTier" -MemberType NoteProperty, Property) { [int]$item.dependencyTier } else { 0 }
            $dependents = if ($item | Get-Member -Name "dependentMods" -MemberType NoteProperty, Property) { [int]$item.dependentMods } else { -1 }
            $known = if ($item | Get-Member -Name "dependentModsKnown" -MemberType NoteProperty, Property) { [bool]$item.dependentModsKnown } else { $false }
            $compatPriorityChoices += @([pscustomobject]@{
                ModId = $modId
                Tier = $tier
                DependentCount = $dependents
                Known = $known
                Status = $status
                Decision = $decision
              })
          }
        }
      }
    } catch {
      Write-Host ("Warning: failed to read compatibility priority details: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
  } elseif (-not [string]::IsNullOrWhiteSpace($CompatReportPath) -and (Test-Path -LiteralPath $CompatReportPath) -and (-not $compatReportFresh)) {
    Write-Host "Compatibility report for this session is unavailable; priority details skipped." -ForegroundColor Gray
  }

  $historyMoves = @($CulpritHistoryByJar.Values | Where-Object { $null -ne $_ })
  if (-not $historyMoves -or $historyMoves.Count -eq 0) {
    Write-Host "No culprits detected in this session." -ForegroundColor Green
  } else {
    # * Group culprits by stage for detailed report.
    $byStage = @{}
    foreach ($move in $historyMoves) {
      if ($null -eq $move) { continue }
      $jarName = [string]$move.JarName
      if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
      $stage = "unknown"
      if ($move | Get-Member -Name "Stage" -MemberType NoteProperty, Property) {
        $s = [string]$move.Stage
        if (-not [string]::IsNullOrWhiteSpace($s)) { $stage = $s }
      }
      if (-not $byStage.ContainsKey($stage)) { $byStage[$stage] = @() }
      $byStage[$stage] += @($move)
    }

    $uniqueMoves = @($historyMoves | Sort-Object -Property JarName -Unique)
    Write-Host ("Culprits detected: {0}" -f $uniqueMoves.Count) -ForegroundColor Yellow

    # * Display by stage.
    $stageLabels = @{
      "compatibility-cleanup" = "Baseline Analysis"
      "mixin-analysis" = "Mixin Analysis"
      "layering"       = "Layering"
      "isolation"      = "Isolation"
      "recovery"       = "Recovery"
      "unknown"        = "Other"
    }
    foreach ($stage in @("compatibility-cleanup", "mixin-analysis", "layering", "isolation", "recovery", "unknown")) {
      if (-not $byStage.ContainsKey($stage)) { continue }
      $stageLabel = if ($stageLabels.ContainsKey($stage)) { $stageLabels[$stage] } else { $stage }
      $stageMoves = @($byStage[$stage])
      Write-Host ("  [{0}] ({1}):" -f $stageLabel, $stageMoves.Count) -ForegroundColor Gray
      foreach ($move in ($stageMoves | Sort-Object -Property JarName)) {
        $jarName = [string]$move.JarName
        $locations = New-Object System.Collections.Generic.List[string]
        $storagePath = [string]$move.StorageLegacyPath
        $gamePath = [string]$move.GameLegacyPath
        if (-not [string]::IsNullOrWhiteSpace($storagePath)) { $locations.Add(("storage: {0}" -f $storagePath)) }
        if (-not [string]::IsNullOrWhiteSpace($gamePath)) { $locations.Add(("game: {0}" -f $gamePath)) }
        $locationLabel = if ($locations.Count -gt 0) { $locations -join "; " } else { "location unknown" }
        $priorityParts = New-Object System.Collections.Generic.List[string]
        if ($move | Get-Member -Name "DependencyTier" -MemberType NoteProperty, Property) {
          $tier = [int]$move.DependencyTier
          if ($tier -gt 0) {
            $priorityParts.Add(("tier={0}" -f $tier)) | Out-Null
          }
        }
        if ($move | Get-Member -Name "DependentModCount" -MemberType NoteProperty, Property) {
          $depCount = [int]$move.DependentModCount
          if ($depCount -ge 0) {
            $priorityParts.Add(("dependents={0}" -f $depCount)) | Out-Null
          }
        }
        $line = ("    - {0} ({1})" -f $jarName, $locationLabel)
        if ($priorityParts.Count -gt 0) {
          $line = "{0}; {1}" -f $line, ($priorityParts -join ", ")
        }
        Write-Host $line -ForegroundColor Gray
        if ($move | Get-Member -Name "PriorityDecision" -MemberType NoteProperty, Property) {
          $reason = [string]$move.PriorityDecision
          if (-not [string]::IsNullOrWhiteSpace($reason)) {
            Write-Host ("      reason: {0}" -f $reason) -ForegroundColor Gray
          }
        }
      }
    }
  }

  if ($compatPriorityChoices -and $compatPriorityChoices.Count -gt 0) {
    Write-Host ("Compatibility cleanup priority decisions: {0}" -f $compatPriorityChoices.Count) -ForegroundColor Gray
    foreach ($item in ($compatPriorityChoices | Sort-Object -Property Tier, DependentCount, ModId)) {
      $countLabel = if ($item.Known -and $item.DependentCount -ge 0) { [string]$item.DependentCount } else { "unknown" }
      $decisionLabel = if ([string]::IsNullOrWhiteSpace([string]$item.Decision)) { "selected by dependency priority" } else { [string]$item.Decision }
      Write-Host ("  - {0} [{1}] tier={2}, dependents={3}; {4}" -f $item.ModId, $item.Status, $item.Tier, $countLabel, $decisionLabel) -ForegroundColor Gray
    }
  }

  # * Show recovered (restored) mods from phantom culprit recovery.
  if ($RecoveredJarNames -and $RecoveredJarNames.Count -gt 0) {
    $recoveredNames = @($RecoveredJarNames.Values | Sort-Object -Unique)
    Write-Host ("Recovered (restored from false positive): {0}" -f $recoveredNames.Count) -ForegroundColor Green
    foreach ($rn in $recoveredNames) {
      Write-Host ("  + {0}" -f $rn) -ForegroundColor Green
    }
  }

  # * Show Mixin conflict info and developer notification recommendation.
  if ($MixinConflicts -and $MixinConflicts.Count -gt 0) {
    Write-Host ""
    Write-Host ("Mixin conflicts detected ({0}):" -f $MixinConflicts.Count) -ForegroundColor Cyan
    foreach ($conflict in $MixinConflicts) {
      $srcLabel = [string]$conflict.SourceModId
      $srcJar = [string]$conflict.SourceJar
      $tgtLabel = if (-not [string]::IsNullOrWhiteSpace([string]$conflict.TargetModId)) { [string]$conflict.TargetModId } else { [string]$conflict.TargetClass }
      $tgtJar = [string]$conflict.TargetJar
      $srcDisplay = if (-not [string]::IsNullOrWhiteSpace($srcJar)) { "{0} ({1})" -f $srcLabel, $srcJar } else { $srcLabel }
      $tgtDisplay = if (-not [string]::IsNullOrWhiteSpace($tgtJar)) { "{0} ({1})" -f $tgtLabel, $tgtJar } else { $tgtLabel }
      Write-Host ("  {0} → {1}" -f $srcDisplay, $tgtDisplay) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "Please report these incompatibilities to the developers of the affected mods" -ForegroundColor Yellow
    Write-Host "so they can fix the broken Mixin references in future updates." -ForegroundColor Yellow
  }

  $currentNames = @($CulpritCurrentByJar.Values |
      ForEach-Object { $_.JarName } |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
      Sort-Object -Unique)
  if ($currentNames -and $currentNames.Count -gt 0) {
    Write-Host ("Currently isolated mods: {0}" -f ($currentNames -join ", ")) -ForegroundColor Yellow
  }
}

function Format-IsolationParamsForDisplay {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Params
  )

  $prettyParams = @()
  foreach ($key in ($Params.Keys | Sort-Object)) {
    $value = $Params[$key]
    if ($value -is [System.Array]) {
      $prettyParams += @(("-{0} [{1}]" -f $key, (($value | ForEach-Object { "'{0}'" -f $_ }) -join ", ")))
    } else {
      $prettyParams += @(("-{0} '{1}'" -f $key, $value))
    }
  }
  # ! Use unary comma to prevent single-element unwrapping (avoids char-by-char splatting).
  return ,@($prettyParams)
}
