function Get-McccFolderPolicyMap {
  return [ordered]@{
    GameLegacy = "legacy"
    StorageLegacy = "Legacy"
    Updated = "Updated"
  }
}

function Resolve-McccFolderName {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("GameLegacy", "StorageLegacy", "Updated")]
    [string]$Role,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$FolderName = ""
  )

  if (-not [string]::IsNullOrWhiteSpace($FolderName)) {
    return $FolderName.Trim()
  }

  $policy = Get-McccFolderPolicyMap
  if (-not $policy.Contains($Role)) {
    throw ("Unknown folder role: {0}" -f $Role)
  }
  return [string]$policy[$Role]
}

function Resolve-McccLegacyFolderNames {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$GameLegacyFolderName = "",
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$StorageLegacyFolderName = ""
  )

  return [pscustomobject]@{
    GameLegacyFolderName = Resolve-McccFolderName -Role "GameLegacy" -FolderName $GameLegacyFolderName
    StorageLegacyFolderName = Resolve-McccFolderName -Role "StorageLegacy" -FolderName $StorageLegacyFolderName
  }
}

function Get-McccLegacyFolderCandidates {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("GameLegacy", "StorageLegacy")]
    [string]$Role,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$AdditionalCandidates = @()
  )

  $result = New-Object System.Collections.Generic.List[string]
  $seen = @{}
  $addCandidate = {
    param(
      [Parameter(Mandatory = $true)]
      [AllowEmptyString()]
      [string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $value = $Name.Trim()
    $key = $value.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { return }
    $seen[$key] = $true
    $result.Add($value) | Out-Null
  }

  $canonical = Resolve-McccFolderName -Role $Role
  & $addCandidate $canonical

  if ($Role -eq "GameLegacy") {
    & $addCandidate "Legacy"
  } else {
    & $addCandidate "legacy"
  }

  foreach ($name in @($AdditionalCandidates)) {
    & $addCandidate ([string]$name)
  }

  return @($result.ToArray())
}

function Get-McccLegacyTempRootPath {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$ModsDir,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$GameLegacyFolderName = ""
  )

  if ([string]::IsNullOrWhiteSpace($ModsDir)) {
    return ""
  }

  $resolvedGameLegacyFolderName = Resolve-McccFolderName -Role "GameLegacy" -FolderName $GameLegacyFolderName
  $legacyRoot = Join-Path -Path $ModsDir -ChildPath $resolvedGameLegacyFolderName
  return (Join-Path -Path $legacyRoot -ChildPath "temp")
}

function Join-McccDestinationPath {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$SourcePath,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$DestinationDirectory
  )

  if ([string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($DestinationDirectory)) {
    return ""
  }
  return (Join-Path -Path $DestinationDirectory -ChildPath ([System.IO.Path]::GetFileName($SourcePath)))
}

function New-McccFileOpResult {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Operation,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$SourcePath = "",
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$DestinationPath = "",
    [Parameter(Mandatory = $true)]
    [bool]$SourceExists,
    [Parameter(Mandatory = $true)]
    [bool]$Performed,
    [Parameter(Mandatory = $true)]
    [bool]$Skipped,
    [Parameter(Mandatory = $true)]
    [bool]$DryRun,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$Message = ""
  )

  return [pscustomobject]@{
    Operation = $Operation
    SourcePath = $SourcePath
    DestinationPath = $DestinationPath
    SourceExists = [bool]$SourceExists
    Performed = [bool]$Performed
    Skipped = [bool]$Skipped
    DryRun = [bool]$DryRun
    Message = $Message
  }
}

function Invoke-McccWithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$Action,
    [Parameter(Mandatory = $false)]
    [string]$OperationName = "operation",
    [Parameter(Mandatory = $false)]
    [int]$RetryCount = 0,
    [Parameter(Mandatory = $false)]
    [int]$RetryDelayMs = 0
  )

  if ($RetryCount -lt 0) { $RetryCount = 0 }
  if ($RetryDelayMs -lt 0) { $RetryDelayMs = 0 }

  $maxAttempts = $RetryCount + 1
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
      return (& $Action)
    } catch [System.IO.IOException] {
      if ($attempt -ge $maxAttempts) {
        throw ("{0} failed after {1} attempt(s): {2}" -f $OperationName, $maxAttempts, $_.Exception.Message)
      }
      if ($RetryDelayMs -gt 0) {
        Start-Sleep -Milliseconds $RetryDelayMs
      }
      continue
    } catch {
      throw
    }
  }
}

function Move-McccItem {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$LiteralPath,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$DestinationPath,
    [Parameter(Mandatory = $false)]
    [bool]$DryRun = $false,
    [Parameter(Mandatory = $false)]
    [bool]$Overwrite = $true,
    [Parameter(Mandatory = $false)]
    [int]$RetryCount = 0,
    [Parameter(Mandatory = $false)]
    [int]$RetryDelayMs = 0
  )

  $sourceExists = -not [string]::IsNullOrWhiteSpace($LiteralPath) -and (Test-Path -LiteralPath $LiteralPath)
  if (-not $sourceExists) {
    return (New-McccFileOpResult -Operation "move" -SourcePath $LiteralPath -DestinationPath $DestinationPath -SourceExists $false -Performed $false -Skipped $true -DryRun:$DryRun)
  }
  if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    throw ("DestinationPath is required for move operation: {0}" -f $LiteralPath)
  }

  if ($DryRun) {
    return (New-McccFileOpResult -Operation "move" -SourcePath $LiteralPath -DestinationPath $DestinationPath -SourceExists $true -Performed $false -Skipped $false -DryRun:$true -Message ("DRYRUN move: {0} -> {1}" -f $LiteralPath, $DestinationPath))
  }

  if ((Test-Path -LiteralPath $DestinationPath) -and (-not $Overwrite)) {
    return (New-McccFileOpResult -Operation "move" -SourcePath $LiteralPath -DestinationPath $DestinationPath -SourceExists $true -Performed $false -Skipped $true -DryRun:$false -Message ("move skipped (exists): {0}" -f $DestinationPath))
  }

  $destinationParent = Split-Path -Path $DestinationPath -Parent
  if (-not [string]::IsNullOrWhiteSpace($destinationParent) -and -not (Test-Path -LiteralPath $destinationParent)) {
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
  }

  $operationName = "Move '{0}' -> '{1}'" -f $LiteralPath, $DestinationPath
  Invoke-McccWithRetry -Action {
    Move-Item -LiteralPath $LiteralPath -Destination $DestinationPath -Force:$Overwrite -ErrorAction Stop
  } -OperationName $operationName -RetryCount $RetryCount -RetryDelayMs $RetryDelayMs | Out-Null

  return (New-McccFileOpResult -Operation "move" -SourcePath $LiteralPath -DestinationPath $DestinationPath -SourceExists $true -Performed $true -Skipped $false -DryRun:$false -Message ("moved: {0} -> {1}" -f $LiteralPath, $DestinationPath))
}

function Copy-McccItem {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$LiteralPath,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$DestinationPath,
    [Parameter(Mandatory = $false)]
    [bool]$DryRun = $false,
    [Parameter(Mandatory = $false)]
    [bool]$Overwrite = $true,
    [Parameter(Mandatory = $false)]
    [int]$RetryCount = 0,
    [Parameter(Mandatory = $false)]
    [int]$RetryDelayMs = 0
  )

  $sourceExists = -not [string]::IsNullOrWhiteSpace($LiteralPath) -and (Test-Path -LiteralPath $LiteralPath)
  if (-not $sourceExists) {
    return (New-McccFileOpResult -Operation "copy" -SourcePath $LiteralPath -DestinationPath $DestinationPath -SourceExists $false -Performed $false -Skipped $true -DryRun:$DryRun)
  }
  if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    throw ("DestinationPath is required for copy operation: {0}" -f $LiteralPath)
  }

  if ($DryRun) {
    return (New-McccFileOpResult -Operation "copy" -SourcePath $LiteralPath -DestinationPath $DestinationPath -SourceExists $true -Performed $false -Skipped $false -DryRun:$true -Message ("DRYRUN copy: {0} -> {1}" -f $LiteralPath, $DestinationPath))
  }

  if ((Test-Path -LiteralPath $DestinationPath) -and (-not $Overwrite)) {
    return (New-McccFileOpResult -Operation "copy" -SourcePath $LiteralPath -DestinationPath $DestinationPath -SourceExists $true -Performed $false -Skipped $true -DryRun:$false -Message ("copy skipped (exists): {0}" -f $DestinationPath))
  }

  $destinationParent = Split-Path -Path $DestinationPath -Parent
  if (-not [string]::IsNullOrWhiteSpace($destinationParent) -and -not (Test-Path -LiteralPath $destinationParent)) {
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
  }

  $operationName = "Copy '{0}' -> '{1}'" -f $LiteralPath, $DestinationPath
  Invoke-McccWithRetry -Action {
    Copy-Item -LiteralPath $LiteralPath -Destination $DestinationPath -Force:$Overwrite -ErrorAction Stop
  } -OperationName $operationName -RetryCount $RetryCount -RetryDelayMs $RetryDelayMs | Out-Null

  return (New-McccFileOpResult -Operation "copy" -SourcePath $LiteralPath -DestinationPath $DestinationPath -SourceExists $true -Performed $true -Skipped $false -DryRun:$false -Message ("copied: {0} -> {1}" -f $LiteralPath, $DestinationPath))
}

function Remove-McccItem {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$LiteralPath,
    [Parameter(Mandatory = $false)]
    [bool]$DryRun = $false,
    [Parameter(Mandatory = $false)]
    [bool]$Overwrite = $true,
    [Parameter(Mandatory = $false)]
    [int]$RetryCount = 0,
    [Parameter(Mandatory = $false)]
    [int]$RetryDelayMs = 0
  )

  $sourceExists = -not [string]::IsNullOrWhiteSpace($LiteralPath) -and (Test-Path -LiteralPath $LiteralPath)
  if (-not $sourceExists) {
    return (New-McccFileOpResult -Operation "delete" -SourcePath $LiteralPath -DestinationPath "" -SourceExists $false -Performed $false -Skipped $true -DryRun:$DryRun)
  }

  if ($DryRun) {
    return (New-McccFileOpResult -Operation "delete" -SourcePath $LiteralPath -DestinationPath "" -SourceExists $true -Performed $false -Skipped $false -DryRun:$true -Message ("DRYRUN delete: {0}" -f $LiteralPath))
  }

  $operationName = "Delete '{0}'" -f $LiteralPath
  Invoke-McccWithRetry -Action {
    Remove-Item -LiteralPath $LiteralPath -Force:$Overwrite -ErrorAction Stop
  } -OperationName $operationName -RetryCount $RetryCount -RetryDelayMs $RetryDelayMs | Out-Null

  return (New-McccFileOpResult -Operation "delete" -SourcePath $LiteralPath -DestinationPath "" -SourceExists $true -Performed $true -Skipped $false -DryRun:$false -Message ("deleted: {0}" -f $LiteralPath))
}
