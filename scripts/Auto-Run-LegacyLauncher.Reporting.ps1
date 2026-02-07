function Get-LatestCompatReportPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ReportDir
  )

  if (-not (Test-Path -LiteralPath $ReportDir)) { return "" }
  $reports = Get-ChildItem -LiteralPath $ReportDir -Filter "compat-report-*.json" -File -ErrorAction SilentlyContinue |
    Sort-Object -Property LastWriteTime -Descending
  if (-not $reports -or $reports.Count -eq 0) { return "" }
  return [string]$reports[0].FullName
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
  Write-Host "Session report" -ForegroundColor Cyan
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
      "mixin-analysis" = "Mixin analysis"
      "layering"       = "Layering"
      "isolation"      = "Subtractive isolation"
      "recovery"       = "Recovery (root cause)"
      "unknown"        = "Other"
    }
    foreach ($stage in @("mixin-analysis", "layering", "isolation", "recovery", "unknown")) {
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
        Write-Host ("    - {0} ({1})" -f $jarName, $locationLabel) -ForegroundColor Gray
      }
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
