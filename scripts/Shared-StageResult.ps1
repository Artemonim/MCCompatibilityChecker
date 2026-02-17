function New-StageResult {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Stage,
    [Parameter(Mandatory = $false)]
    [string]$Type = "StageResult",
    [Parameter(Mandatory = $false)]
    [string]$RunId = "",
    [Parameter(Mandatory = $false)]
    [string]$GameModsDir = "",
    [Parameter(Mandatory = $false)]
    [string]$StorageModsDir = "",
    [Parameter(Mandatory = $false)]
    [string]$Minecraft = "",
    [Parameter(Mandatory = $false)]
    [int]$ExitCode = 0,
    [Parameter(Mandatory = $false)]
    [string[]]$CulpritJarNames = @(),
    [Parameter(Mandatory = $false)]
    [object[]]$CulpritMoves = @(),
    [Parameter(Mandatory = $false)]
    [bool]$HashCacheEnabled = $false,
    [Parameter(Mandatory = $false)]
    [string]$HashCachePath = "",
    [Parameter(Mandatory = $false)]
    [string[]]$HashCacheSkippedJarNames = @(),
    [Parameter(Mandatory = $false)]
    [string]$BaselineOutcome = "",
    [Parameter(Mandatory = $false)]
    [string]$BaselineSignature = "",
    [Parameter(Mandatory = $false)]
    [string]$BaselineEvidenceKey = "",
    [Parameter(Mandatory = $false)]
    [string]$StopReason = "",
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$Warnings = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$Errors = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$Diagnostics = @(),
    [Parameter(Mandatory = $false)]
    [hashtable]$ExtraFields = $null
  )

  $normalizedWarnings = @()
  foreach ($warningRecord in @($Warnings)) {
    if ($null -eq $warningRecord) { continue }
    $normalizedWarnings += $warningRecord
  }

  $normalizedErrors = @()
  foreach ($errorRecord in @($Errors)) {
    if ($null -eq $errorRecord) { continue }
    $normalizedErrors += $errorRecord
  }

  $normalizedDiagnostics = @()
  foreach ($diagnosticRecord in @($Diagnostics)) {
    if ($null -eq $diagnosticRecord) { continue }
    $normalizedDiagnostics += $diagnosticRecord
  }
  if ($normalizedDiagnostics.Count -eq 0 -and ($normalizedWarnings.Count -gt 0 -or $normalizedErrors.Count -gt 0)) {
    $normalizedDiagnostics = @($normalizedWarnings + $normalizedErrors)
  }

  $result = [ordered]@{
    Type                     = $Type
    Stage                    = $Stage
    RunId                    = $RunId
    GameModsDir              = $GameModsDir
    StorageModsDir           = $StorageModsDir
    Minecraft                = $Minecraft
    ExitCode                 = $ExitCode
    CulpritJarNames          = @($CulpritJarNames)
    CulpritMoves             = @($CulpritMoves)
    HashCacheEnabled         = $HashCacheEnabled
    HashCachePath            = $HashCachePath
    HashCacheSkippedJarNames = @($HashCacheSkippedJarNames)
    BaselineOutcome          = $BaselineOutcome
    BaselineSignature        = $BaselineSignature
    BaselineEvidenceKey      = $BaselineEvidenceKey
    StopReason               = $StopReason
    Warnings                 = @($normalizedWarnings)
    Errors                   = @($normalizedErrors)
    Diagnostics              = @($normalizedDiagnostics)
  }

  if ($null -ne $ExtraFields) {
    foreach ($key in $ExtraFields.Keys) {
      $result[$key] = $ExtraFields[$key]
    }
  }

  return [pscustomobject]$result
}

function New-McccDiagnosticRecord {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Warning", "Error", "Info")]
    [string]$Severity,
    [Parameter(Mandatory = $true)]
    [string]$Category,
    [Parameter(Mandatory = $false)]
    [string]$Code = "",
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Message,
    [Parameter(Mandatory = $false)]
    [hashtable]$Context = @{},
    [Parameter(Mandatory = $false)]
    [string]$ExceptionType = ""
  )

  return [pscustomobject]@{
    Severity      = $Severity
    Category      = $Category
    Code          = $Code
    Message       = $Message
    Context       = if ($null -eq $Context) { @{} } else { $Context }
    ExceptionType = $ExceptionType
  }
}

function New-McccWarningRecord {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Category,
    [Parameter(Mandatory = $false)]
    [string]$Code = "",
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Message,
    [Parameter(Mandatory = $false)]
    [hashtable]$Context = @{},
    [Parameter(Mandatory = $false)]
    [string]$ExceptionType = ""
  )

  return New-McccDiagnosticRecord `
    -Severity "Warning" `
    -Category $Category `
    -Code $Code `
    -Message $Message `
    -Context $Context `
    -ExceptionType $ExceptionType
}

function New-McccErrorRecord {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Category,
    [Parameter(Mandatory = $false)]
    [string]$Code = "",
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Message,
    [Parameter(Mandatory = $false)]
    [hashtable]$Context = @{},
    [Parameter(Mandatory = $false)]
    [string]$ExceptionType = ""
  )

  return New-McccDiagnosticRecord `
    -Severity "Error" `
    -Category $Category `
    -Code $Code `
    -Message $Message `
    -Context $Context `
    -ExceptionType $ExceptionType
}

function New-McccStageAccumulator {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Stage
  )

  return [pscustomobject]@{
    Stage       = $Stage
    Warnings    = [System.Collections.Generic.List[object]]::new()
    Errors      = [System.Collections.Generic.List[object]]::new()
    Diagnostics = [System.Collections.Generic.List[object]]::new()
  }
}

function Add-McccStageWarning {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Accumulator,
    [Parameter(Mandatory = $true)]
    [string]$Category,
    [Parameter(Mandatory = $false)]
    [string]$Code = "",
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Message,
    [Parameter(Mandatory = $false)]
    [hashtable]$Context = @{},
    [Parameter(Mandatory = $false)]
    [string]$ExceptionType = ""
  )

  $record = New-McccWarningRecord `
    -Category $Category `
    -Code $Code `
    -Message $Message `
    -Context $Context `
    -ExceptionType $ExceptionType
  $Accumulator.Warnings.Add($record) | Out-Null
  $Accumulator.Diagnostics.Add($record) | Out-Null
  return $record
}

function Add-McccStageError {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Accumulator,
    [Parameter(Mandatory = $true)]
    [string]$Category,
    [Parameter(Mandatory = $false)]
    [string]$Code = "",
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Message,
    [Parameter(Mandatory = $false)]
    [hashtable]$Context = @{},
    [Parameter(Mandatory = $false)]
    [string]$ExceptionType = ""
  )

  $record = New-McccErrorRecord `
    -Category $Category `
    -Code $Code `
    -Message $Message `
    -Context $Context `
    -ExceptionType $ExceptionType
  $Accumulator.Errors.Add($record) | Out-Null
  $Accumulator.Diagnostics.Add($record) | Out-Null
  return $record
}

function Complete-McccStageAccumulator {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Accumulator,
    [Parameter(Mandatory = $false)]
    [string]$Type = "InternalStageResult",
    [Parameter(Mandatory = $false)]
    [hashtable]$ExtraFields = $null
  )

  return New-StageResult `
    -Stage ([string]$Accumulator.Stage) `
    -Type $Type `
    -Warnings @($Accumulator.Warnings.ToArray()) `
    -Errors @($Accumulator.Errors.ToArray()) `
    -Diagnostics @($Accumulator.Diagnostics.ToArray()) `
    -ExtraFields $ExtraFields
}

function Set-McccStageResult {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$StageResults,
    [Parameter(Mandatory = $true)]
    [pscustomobject]$StageResult
  )

  $stageName = [string]$StageResult.Stage
  if ([string]::IsNullOrWhiteSpace($stageName)) { return }
  $StageResults[$stageName] = $StageResult
}

function Get-McccStageDiagnosticsSummary {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$StageResults
  )

  $warnings = [System.Collections.Generic.List[object]]::new()
  $errors = [System.Collections.Generic.List[object]]::new()
  $diagnostics = [System.Collections.Generic.List[object]]::new()

  foreach ($entry in @($StageResults.Values)) {
    if ($null -eq $entry) { continue }
    foreach ($record in @($entry.Warnings)) {
      if ($null -eq $record) { continue }
      $warnings.Add($record) | Out-Null
    }
    foreach ($record in @($entry.Errors)) {
      if ($null -eq $record) { continue }
      $errors.Add($record) | Out-Null
    }
    if ($entry.Diagnostics -and @($entry.Diagnostics).Count -gt 0) {
      foreach ($record in @($entry.Diagnostics)) {
        if ($null -eq $record) { continue }
        $diagnostics.Add($record) | Out-Null
      }
    } else {
      foreach ($record in @($entry.Warnings)) {
        if ($null -eq $record) { continue }
        $diagnostics.Add($record) | Out-Null
      }
      foreach ($record in @($entry.Errors)) {
        if ($null -eq $record) { continue }
        $diagnostics.Add($record) | Out-Null
      }
    }
  }

  return [pscustomobject]@{
    Warnings    = @($warnings.ToArray())
    Errors      = @($errors.ToArray())
    Diagnostics = @($diagnostics.ToArray())
  }
}

function Select-StageResultObject {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [object]$Result
  )

  if ($null -eq $Result) { return $null }
  if ($Result -is [System.Array]) {
    if ($Result.Count -gt 0) { return $Result[$Result.Count - 1] }
    return $null
  }
  return $Result
}
