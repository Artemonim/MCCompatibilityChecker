function Add-SessionDependencyMapParam {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Params,
    [Parameter(Mandatory = $false)]
    [bool]$RequireFile = $false
  )

  if ($null -eq $Params) { return }

  if ([bool]$script:sessionDependencyMapAvailable -and (-not [string]::IsNullOrWhiteSpace([string]$script:sessionDependencyMapJsonPath))) {
    $Params["DependencyMapSource"] = "File"
    $Params["DependencyMapJsonPath"] = [string]$script:sessionDependencyMapJsonPath
    return
  }

  if ($RequireFile) { return }

  if (-not [string]::IsNullOrWhiteSpace([string]$script:sessionDependencyMapToolPath)) {
    $Params["DependencyMapToolPath"] = [string]$script:sessionDependencyMapToolPath
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$script:sessionDependencyMapOutDir)) {
    $Params["DependencyMapOutDir"] = [string]$script:sessionDependencyMapOutDir
  }
}

function Test-ExtraArgsContainNamedParam {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$Args = @(),
    [Parameter(Mandatory = $true)]
    [string]$ParamName
  )

  if ([string]::IsNullOrWhiteSpace($ParamName)) { return $false }
  if (-not $Args -or $Args.Count -eq 0) { return $false }

  $escaped = [regex]::Escape($ParamName)
  $pattern = "^-{1,2}{0}(?:$|:|=)" -f $escaped
  foreach ($arg in $Args) {
    $value = [string]$arg
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    if ($value -match $pattern) { return $true }
  }
  return $false
}

function Initialize-SessionDependencyMap {
  param(
    [Parameter(Mandatory = $false)]
    [string]$Reason = ""
  )

  if ([bool]$script:sessionDependencyMapPrepared) {
    return [bool]$script:sessionDependencyMapAvailable
  }

  $script:sessionDependencyMapPrepared = $true
  $script:sessionDependencyMapPreparedReason = $Reason
  $script:sessionDependencyMapAvailable = $false
  $script:sessionDependencyMapJsonPath = ""

  if ([bool]$DryRun) { return $false }

  $gameModsDir = ""
  if ($null -ne $runtimeConfig -and $null -ne $runtimeConfig.Paths) {
    $gameModsDir = [string]$runtimeConfig.Paths.GameModsDir
  }
  if ([string]::IsNullOrWhiteSpace($gameModsDir) -or (-not (Test-Path -LiteralPath $gameModsDir))) {
    Write-Host ("Warning: cannot build dependency map; GameModsDir is unavailable: {0}" -f $gameModsDir) -ForegroundColor Yellow
    return $false
  }

  $toolPath = [string]$script:sessionDependencyMapToolPath
  if ([string]::IsNullOrWhiteSpace($toolPath)) {
    $toolPath = Join-Path -Path $PSScriptRoot -ChildPath "..\tools\Analyze-JarDependencyMap.ps1"
  }
  if (-not (Test-Path -LiteralPath $toolPath)) {
    Write-Host ("Warning: dependency map tool not found: {0}" -f $toolPath) -ForegroundColor Yellow
    return $false
  }

  $outDir = [string]$script:sessionDependencyMapOutDir
  if ([string]::IsNullOrWhiteSpace($outDir)) {
    $outDir = Join-Path -Path $PSScriptRoot -ChildPath "..\reports"
  }
  if (-not (Test-Path -LiteralPath $outDir)) {
    try {
      [void](New-Item -Path $outDir -ItemType Directory -Force -ErrorAction Stop)
    } catch {
      Write-Host ("Warning: failed to create dependency map output directory: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
      return $false
    }
  }

  try {
    & $toolPath -ScanPath $gameModsDir -NoRecurse -WriteFiles:$true -OutDir $outDir -TopDependencies 0 | Out-Null
  } catch {
    Write-Host ("Warning: dependency map build failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    return $false
  }

  $jsonPath = Join-Path -Path $outDir -ChildPath "jar-dependency-map.json"
  if (-not (Test-Path -LiteralPath $jsonPath)) {
    Write-Host ("Warning: dependency map JSON was not generated: {0}" -f $jsonPath) -ForegroundColor Yellow
    return $false
  }

  try {
    $raw = Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "dependency map json is empty" }
    [void]($raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    Write-Host ("Warning: dependency map JSON is invalid: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    return $false
  }

  $script:sessionDependencyMapJsonPath = (Resolve-Path -LiteralPath $jsonPath).Path
  $script:sessionDependencyMapToolPath = $toolPath
  $script:sessionDependencyMapOutDir = $outDir
  $script:sessionDependencyMapAvailable = $true
  $reasonSuffix = if ([string]::IsNullOrWhiteSpace($Reason)) { "" } else { " ({0})" -f $Reason }
  Write-Host ("Dependency map prepared once{0} and will be reused: {1}" -f $reasonSuffix, $script:sessionDependencyMapJsonPath) -ForegroundColor Gray
  return $true
}

function Get-CompatibilityParam {
  param(
    [Parameter(Mandatory = $false)]
    [datetime]$LogSinceTimestamp = [datetime]::MinValue
  )

  $compatParams = @{}
  if ($DeleteFromGameMods) {
    $compatParams["DeleteFromGameMods"] = $true
  }
  if ($NoLegacy) {
    $compatParams["NoLegacy"] = $true
  }
  if ($GameLegacy) {
    $compatParams["GameLegacy"] = $true
  }
  if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
    $compatParams["LogPath"] = $LogPath
  }
  if ($IgnoreModIds -and $IgnoreModIds.Count -gt 0) {
    $compatParams["IgnoreModIds"] = $IgnoreModIds
  }
  if ($script:checkScriptSupportsSince -and $LogSinceTimestamp -ne [datetime]::MinValue) {
    $compatParams["LogSinceTimestamp"] = $LogSinceTimestamp
  }
  $compatHasDepMapOverride = (Test-ExtraArgsContainNamedParam -Args $CheckScriptArguments -ParamName "DependencyMapSource") -or
    (Test-ExtraArgsContainNamedParam -Args $CheckScriptArguments -ParamName "DependencyMapJsonPath") -or
    (Test-ExtraArgsContainNamedParam -Args $CheckScriptArguments -ParamName "DependencyMapToolPath") -or
    (Test-ExtraArgsContainNamedParam -Args $CheckScriptArguments -ParamName "DependencyMapOutDir")
  if (-not $compatHasDepMapOverride) {
    Add-SessionDependencyMapParam -Params $compatParams -RequireFile $false
  }
  return $compatParams
}

function Get-CompatibilityExtraArg {
  $compatArgs = @()
  if ($CheckScriptArguments) {
    foreach ($arg in $CheckScriptArguments) {
      if (-not [string]::IsNullOrWhiteSpace($arg)) {
        $compatArgs += @($arg)
      }
    }
  }
  # ! Use unary comma to prevent single-element unwrapping (avoids char-by-char splatting).
  return ,@($compatArgs)
}

function Get-IsolationExtraArg {
  $isolateExtraArgs = @()
  if ($IsolateScriptArguments) {
    foreach ($arg in $IsolateScriptArguments) {
      if (-not [string]::IsNullOrWhiteSpace($arg)) {
        $isolateExtraArgs += @($arg)
      }
    }
  }
  # ! Use unary comma to prevent single-element unwrapping (avoids char-by-char splatting).
  return ,@($isolateExtraArgs)
}

function Get-BaseLauncherParam {
  param(
    [Parameter(Mandatory = $false)]
    [bool]$IncludeLogPath = $true,
    [Parameter(Mandatory = $false)]
    [bool]$UseOutcomeTimeoutWhenBound = $false
  )

  $params = @{}
  if (-not [string]::IsNullOrWhiteSpace($LauncherExePath)) {
    $params["LauncherExePath"] = $LauncherExePath
  }
  if ($LauncherArguments -and $LauncherArguments.Count -gt 0) {
    $params["LauncherArguments"] = $LauncherArguments
  }
  if ($effectiveAutoLaunch) {
    $params["UseAutoLaunch"] = $true
  }
  if (-not [string]::IsNullOrWhiteSpace($LauncherWindowTitlePattern)) {
    $params["LauncherWindowTitlePattern"] = $LauncherWindowTitlePattern
  }
  if ($PlayButtonNames -and $PlayButtonNames.Count -gt 0) {
    $params["PlayButtonNames"] = $PlayButtonNames
  }
  if ($PlayClickOffsetX -ge 0) {
    $params["PlayClickOffsetX"] = $PlayClickOffsetX
  }
  if ($PlayClickOffsetY -ge 0) {
    $params["PlayClickOffsetY"] = $PlayClickOffsetY
  }
  if (-not $UseEnterFallback) {
    $params["UseEnterFallback"] = $false
  }
  if ($EnableBroadUiSearch) {
    $params["EnableBroadUiSearch"] = $true
  }
  if ($CrashWindowTitlePatterns -and $CrashWindowTitlePatterns.Count -gt 0) {
    $params["CrashWindowTitlePatterns"] = $CrashWindowTitlePatterns
  }
  if ($FabricWindowTitlePatterns -and $FabricWindowTitlePatterns.Count -gt 0) {
    $params["FabricWindowTitlePatterns"] = $FabricWindowTitlePatterns
  }
  if ($CrashCloseClickOffsetX -ge 0) {
    $params["CrashCloseClickOffsetX"] = $CrashCloseClickOffsetX
  }
  if ($CrashCloseClickOffsetY -ge 0) {
    $params["CrashCloseClickOffsetY"] = $CrashCloseClickOffsetY
  }
  if ($CrashCloseDelaySeconds -gt 0) {
    $params["CrashCloseDelaySeconds"] = $CrashCloseDelaySeconds
  }
  if ($LauncherWindowTimeoutSeconds -gt 0) {
    $params["LauncherWindowTimeoutSeconds"] = $LauncherWindowTimeoutSeconds
  }
  if ($UseOutcomeTimeoutWhenBound) {
    if ($script:OutcomeTimeoutSecondsBound -and $OutcomeTimeoutSeconds -gt 0) {
      $params["OutcomeTimeoutSeconds"] = $OutcomeTimeoutSeconds
    }
  } elseif ($OutcomeTimeoutSeconds -gt 0) {
    $params["OutcomeTimeoutSeconds"] = $OutcomeTimeoutSeconds
  }
  if ($PollIntervalSeconds -gt 0) {
    $params["PollIntervalSeconds"] = $PollIntervalSeconds
  }
  if ($PlayClickMaxAttempts -gt 0) {
    $params["PlayClickMaxAttempts"] = $PlayClickMaxAttempts
  }
  if ($IncludeLogPath -and -not [string]::IsNullOrWhiteSpace($LogPath)) {
    $params["LogPath"] = $LogPath
  }

  return $params
}

function Get-IsolationParam {
  param(
    [Parameter(Mandatory = $false)]
    [bool]$IncludeEmitResultObject = $false,
    [Parameter(Mandatory = $false)]
    [bool]$IncludeFastForward = $false,
    [Parameter(Mandatory = $false)]
    [bool]$IncludeKeepCulpritInGameLegacy = $false
  )

  $isolateParams = Get-BaseLauncherParam -IncludeLogPath $true -UseOutcomeTimeoutWhenBound $false
  if ($PrintCursorOffset) {
    $isolateParams["PrintCursorOffset"] = $true
  }
  if ($UseLinearIsolation) {
    $isolateParams["UseLinearIsolation"] = $true
  }
  if ($BinaryLinearThreshold -gt 0) {
    $isolateParams["BinaryLinearThreshold"] = $BinaryLinearThreshold
  }
  if ($PSBoundParameters.ContainsKey("Verbose")) {
    $isolateParams["Verbose"] = $true
  }
  if ($IncludeKeepCulpritInGameLegacy -and $GameLegacy) {
    $isolateParams["KeepCulpritInGameLegacy"] = $true
  }
  if ($IncludeEmitResultObject) {
    $isolateParams["EmitResultObject"] = $true
  }
  if ($IncludeFastForward -and $sessionIsolationFastForwardJarNames -and $sessionIsolationFastForwardJarNames.Count -gt 0) {
    Write-Host ("Fast-forward isolation enabled (previously tested mods: {0})." -f $sessionIsolationFastForwardJarNames.Count) -ForegroundColor Gray
    $isolateParams["PreIsolateJarNames"] = $sessionIsolationFastForwardJarNames
    if (-not [string]::IsNullOrWhiteSpace($sessionIsolationFastForwardEvidenceKey)) {
      $isolateParams["PreIsolateBaselineEvidenceKey"] = $sessionIsolationFastForwardEvidenceKey
    }
  }
  if ($NoCache) {
    $isolateParams["NoCache"] = $true
  }

  $effectiveHashCache = ([bool]$UseHashCache) -and (-not [bool]$script:hashCacheDisabledThisSession)
  $isolateParams["UseHashCache"] = [bool]$effectiveHashCache
  if (-not [string]::IsNullOrWhiteSpace($HashCacheFileName)) { $isolateParams["HashCacheFileName"] = $HashCacheFileName }
  if ($HashCacheHashRetryCount -gt 0) { $isolateParams["HashCacheHashRetryCount"] = $HashCacheHashRetryCount }
  if ($HashCacheHashRetryDelayMs -ge 0) { $isolateParams["HashCacheHashRetryDelayMs"] = $HashCacheHashRetryDelayMs }
  $isolateHasDepMapOverride = (Test-ExtraArgsContainNamedParam -Args $IsolateScriptArguments -ParamName "DependencyMapSource") -or
    (Test-ExtraArgsContainNamedParam -Args $IsolateScriptArguments -ParamName "DependencyMapJsonPath") -or
    (Test-ExtraArgsContainNamedParam -Args $IsolateScriptArguments -ParamName "DependencyMapToolPath") -or
    (Test-ExtraArgsContainNamedParam -Args $IsolateScriptArguments -ParamName "DependencyMapOutDir")
  if (-not $isolateHasDepMapOverride) {
    Add-SessionDependencyMapParam -Params $isolateParams -RequireFile $false
  }
  return $isolateParams
}

function Get-LayeringParam {
  param(
    [Parameter(Mandatory = $false)]
    [bool]$IncludeEmitResultObject = $false,
    [Parameter(Mandatory = $false)]
    [bool]$IncludeKeepCulpritInGameLegacy = $false
  )

  $layerParams = Get-BaseLauncherParam -IncludeLogPath $true -UseOutcomeTimeoutWhenBound $true
  if ($PSBoundParameters.ContainsKey("Verbose")) { $layerParams["Verbose"] = $true }
  if ($IncludeKeepCulpritInGameLegacy -and $GameLegacy) {
    $layerParams["KeepCulpritInGameLegacy"] = $true
  }
  if ($ThoroughStabilityCheck) { $layerParams["ThoroughStabilityCheck"] = $true }
  if ($IncludeEmitResultObject) { $layerParams["EmitResultObject"] = $true }
  if ($NoCache) { $layerParams["NoCache"] = $true }

  $effectiveHashCache = ([bool]$UseHashCache) -and (-not [bool]$script:hashCacheDisabledThisSession)
  $layerParams["UseHashCache"] = [bool]$effectiveHashCache
  if (-not [string]::IsNullOrWhiteSpace($HashCacheFileName)) { $layerParams["HashCacheFileName"] = $HashCacheFileName }
  if ($HashCacheHashRetryCount -gt 0) { $layerParams["HashCacheHashRetryCount"] = $HashCacheHashRetryCount }
  if ($HashCacheHashRetryDelayMs -ge 0) { $layerParams["HashCacheHashRetryDelayMs"] = $HashCacheHashRetryDelayMs }
  Add-SessionDependencyMapParam -Params $layerParams -RequireFile $false

  return $layerParams
}

function Get-MixinAnalysisParam {
  param(
    [Parameter(Mandatory = $false)]
    [datetime]$LogSinceTimestamp = [datetime]::MinValue
  )

  # * Builds parameter hashtable for Analyze-MixinErrors.ps1.
  $p = Get-BaseLauncherParam -IncludeLogPath $true -UseOutcomeTimeoutWhenBound $true
  if ($LogSinceTimestamp -ne [datetime]::MinValue) { $p["LogSinceTimestamp"] = $LogSinceTimestamp }
  if ($PSBoundParameters.ContainsKey("Verbose")) { $p["Verbose"] = $true }
  if ($GameLegacy) { $p["KeepCulpritInGameLegacy"] = $true }
  $p["EmitResultObject"] = $true
  Add-SessionDependencyMapParam -Params $p -RequireFile $false
  return $p
}

function Get-RecoveryParam {
  # * Builds parameter hashtable for Recover-PhantomCulprits.ps1.
  $p = Get-BaseLauncherParam -IncludeLogPath $false -UseOutcomeTimeoutWhenBound $true
  if ($PSBoundParameters.ContainsKey("Verbose")) { $p["Verbose"] = $true }
  if ($GameLegacy) { $p["KeepCulpritInGameLegacy"] = $true }
  $p["DependencyMapSource"] = "File"
  Add-SessionDependencyMapParam -Params $p -RequireFile $true
  $p["EmitResultObject"] = $true
  return $p
}
