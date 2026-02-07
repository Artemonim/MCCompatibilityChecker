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
  if ($script:checkScriptSupportsSince -and $LogSinceTimestamp -ne [datetime]::MinValue) {
    $compatParams["LogSinceTimestamp"] = $LogSinceTimestamp
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
  return $p
}

function Get-RecoveryParam {
  # * Builds parameter hashtable for Recover-PhantomCulprits.ps1.
  $p = Get-BaseLauncherParam -IncludeLogPath $false -UseOutcomeTimeoutWhenBound $true
  if ($PSBoundParameters.ContainsKey("Verbose")) { $p["Verbose"] = $true }
  if ($GameLegacy) { $p["KeepCulpritInGameLegacy"] = $true }
  $p["DependencyMapSource"] = "File"
  $p["EmitResultObject"] = $true
  return $p
}
