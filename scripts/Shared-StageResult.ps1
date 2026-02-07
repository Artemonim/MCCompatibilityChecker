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
    [hashtable]$ExtraFields = $null
  )

  $result = [ordered]@{
    Type                   = $Type
    Stage                  = $Stage
    RunId                  = $RunId
    GameModsDir            = $GameModsDir
    StorageModsDir         = $StorageModsDir
    Minecraft              = $Minecraft
    ExitCode               = $ExitCode
    CulpritJarNames        = @($CulpritJarNames)
    CulpritMoves           = @($CulpritMoves)
    HashCacheEnabled       = $HashCacheEnabled
    HashCachePath          = $HashCachePath
    HashCacheSkippedJarNames = @($HashCacheSkippedJarNames)
    BaselineOutcome        = $BaselineOutcome
    BaselineSignature      = $BaselineSignature
    BaselineEvidenceKey    = $BaselineEvidenceKey
    StopReason             = $StopReason
  }

  if ($null -ne $ExtraFields) {
    foreach ($key in $ExtraFields.Keys) {
      $result[$key] = $ExtraFields[$key]
    }
  }

  return [pscustomobject]$result
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
