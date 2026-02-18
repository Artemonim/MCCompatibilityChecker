$sharedFileOpsPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-FileOps.ps1"
if (-not (Test-Path -LiteralPath $sharedFileOpsPath)) {
  throw ("Shared file operation helpers not found: {0}" -f $sharedFileOpsPath)
}
. $sharedFileOpsPath
 
function Move-ToQuarantine {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$SourcePath,
    [Parameter(Mandatory = $true)]
    [string]$DestDir,
    [Parameter(Mandatory = $true)]
    [bool]$IsDryRun,
    [Parameter(Mandatory = $true)]
    [int]$Retries,
    [Parameter(Mandatory = $true)]
    [int]$DelayMs
  )

  if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path -LiteralPath $SourcePath)) {
    return $null
  }
  if ($IsDryRun) {
    return ("DRYRUN move: {0} -> {1}" -f $SourcePath, $DestDir)
  }
  $destPath = Join-McccDestinationPath -SourcePath $SourcePath -DestinationDirectory $DestDir
  $moveResult = Move-McccItem `
    -LiteralPath $SourcePath `
    -DestinationPath $destPath `
    -DryRun $false `
    -Overwrite $true `
    -RetryCount $Retries `
    -RetryDelayMs $DelayMs
  if (-not $moveResult.Performed) {
    return $null
  }
  return $destPath
}

function Restore-FromQuarantine {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$SourcePath,
    [Parameter(Mandatory = $true)]
    [string]$DestDir,
    [Parameter(Mandatory = $true)]
    [bool]$IsDryRun,
    [Parameter(Mandatory = $true)]
    [bool]$AllowOverwrite
  )

  if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path -LiteralPath $SourcePath)) {
    return $null
  }
  if ($IsDryRun) {
    return ("DRYRUN restore: {0} -> {1}" -f $SourcePath, $DestDir)
  }
  $destPath = Join-McccDestinationPath -SourcePath $SourcePath -DestinationDirectory $DestDir
  $restoreResult = Move-McccItem `
    -LiteralPath $SourcePath `
    -DestinationPath $destPath `
    -DryRun $false `
    -Overwrite ([bool]$AllowOverwrite) `
    -RetryCount 0 `
    -RetryDelayMs 0
  if ($restoreResult.Skipped -and (-not $AllowOverwrite) -and (Test-Path -LiteralPath $destPath)) {
    return ("restore skipped (exists): {0}" -f $destPath)
  }
  if (-not $restoreResult.Performed) {
    return $null
  }
  return $destPath
}

function Get-MovedItemByJarName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarName,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $items = $movedItems
  if ($null -ne $Context -and $null -ne $Context.Quarantine -and $Context.Quarantine.MovedItems) {
    $items = $Context.Quarantine.MovedItems
  }
  foreach ($item in $items) {
    if ($null -eq $item) { continue }
    if ([string]$item.JarName -eq $JarName) { return $item }
  }
  return $null
}

function Add-MovedItemRecord {
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarName,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string]$GameSource,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string]$GameQuarantine,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string]$StorageSource,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string]$StorageQuarantine,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $items = $movedItems
  $nameSet = $movedJarNameSet
  if ($null -ne $Context -and $null -ne $Context.Quarantine) {
    if ($Context.Quarantine.MovedItems) { $items = $Context.Quarantine.MovedItems }
    if ($Context.Quarantine.MovedJarNameSet) { $nameSet = $Context.Quarantine.MovedJarNameSet }
  }

  $item = Get-MovedItemByJarName -JarName $JarName -Context $Context
  if ($null -eq $item) {
    $item = [pscustomobject]@{
        JarName = $JarName
        GameSource = $null
        GameQuarantine = $null
        StorageSource = $null
        StorageQuarantine = $null
      }
    $items.Add($item)
  }

  if ($PSBoundParameters.ContainsKey("GameSource")) { $item.GameSource = $GameSource }
  if ($PSBoundParameters.ContainsKey("GameQuarantine")) { $item.GameQuarantine = $GameQuarantine }
  if ($PSBoundParameters.ContainsKey("StorageSource")) { $item.StorageSource = $StorageSource }
  if ($PSBoundParameters.ContainsKey("StorageQuarantine")) { $item.StorageQuarantine = $StorageQuarantine }

  $nameSet[$JarName] = $true
  return $item
}

function Update-QuarantineState {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$DesiredJarNames,
    [Parameter(Mandatory = $false)]
    [string[]]$PinnedJarNames = @(),
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [pscustomobject]$Context = $null
  )

  $desiredSet = @{}
  foreach ($name in $PinnedJarNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $desiredSet[$name.ToLowerInvariant()] = $name
  }
  foreach ($name in $DesiredJarNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $desiredSet[$name.ToLowerInvariant()] = $name
  }

  $items = $movedItems
  $jarNameSet = $movedJarNameSet
  $gameModsDir = $GameModsDir
  $storageModsDir = $StorageModsDir
  $gameQuarantine = $gameQuarantineDir
  $storageQuarantine = $storageQuarantineDir
  $retryCount = $MoveRetryCount
  $retryDelayMs = $MoveRetryDelayMs
  $forceRestore = [bool]$ForceRestore
  $useStorageLocal = [bool]$useStorage

  if ($null -ne $Context) {
    if ($null -ne $Context.Paths) {
      if (-not [string]::IsNullOrWhiteSpace([string]$Context.Paths.GameModsDir)) {
        $gameModsDir = [string]$Context.Paths.GameModsDir
      }
      if ($Context.Paths.PSObject.Properties.Name -contains "StorageModsDir") {
        $storageModsDir = [string]$Context.Paths.StorageModsDir
      }
    }
    if ($null -ne $Context.Quarantine) {
      if ($Context.Quarantine.MovedItems) { $items = $Context.Quarantine.MovedItems }
      if ($Context.Quarantine.MovedJarNameSet) { $jarNameSet = $Context.Quarantine.MovedJarNameSet }
      if ($Context.Quarantine.PSObject.Properties.Name -contains "GameQuarantineDir") {
        $gameQuarantine = [string]$Context.Quarantine.GameQuarantineDir
      }
      if ($Context.Quarantine.PSObject.Properties.Name -contains "StorageQuarantineDir") {
        $storageQuarantine = [string]$Context.Quarantine.StorageQuarantineDir
      }
      if ($Context.Quarantine.PSObject.Properties.Name -contains "MoveRetryCount") {
        $retryCount = [int]$Context.Quarantine.MoveRetryCount
      }
      if ($Context.Quarantine.PSObject.Properties.Name -contains "MoveRetryDelayMs") {
        $retryDelayMs = [int]$Context.Quarantine.MoveRetryDelayMs
      }
      if ($Context.Quarantine.PSObject.Properties.Name -contains "ForceRestore") {
        $forceRestore = [bool]$Context.Quarantine.ForceRestore
      }
      if ($Context.Quarantine.PSObject.Properties.Name -contains "UseStorage") {
        $useStorageLocal = [bool]$Context.Quarantine.UseStorage
      }
    }
  }

  foreach ($item in $items) {
    if ($null -eq $item) { continue }
    $jarName = [string]$item.JarName
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
    $key = $jarName.ToLowerInvariant()
    if ($desiredSet.ContainsKey($key)) { continue }

    if (-not [string]::IsNullOrWhiteSpace($item.GameQuarantine) -and (Test-Path -LiteralPath $item.GameQuarantine)) {
      $restoreGame = Restore-FromQuarantine -SourcePath $item.GameQuarantine `
        -DestDir $gameModsDir `
        -IsDryRun $false `
        -AllowOverwrite $forceRestore
      if ($restoreGame -and (-not (Test-Path -LiteralPath $item.GameQuarantine))) {
        $item.GameQuarantine = $null
      }
    }
    if ($useStorageLocal -and -not [string]::IsNullOrWhiteSpace($item.StorageQuarantine) -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
      $restoreStorage = Restore-FromQuarantine -SourcePath $item.StorageQuarantine `
        -DestDir $storageModsDir `
        -IsDryRun $false `
        -AllowOverwrite $forceRestore
      if ($restoreStorage -and (-not (Test-Path -LiteralPath $item.StorageQuarantine))) {
        $item.StorageQuarantine = $null
      }
    }

    if ($jarNameSet.ContainsKey($jarName)) {
      $null = $jarNameSet.Remove($jarName)
    }
  }

  foreach ($key in $desiredSet.Keys) {
    $jarName = $desiredSet[$key]
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }

    $gamePath = Join-Path -Path $gameModsDir -ChildPath $jarName
    $storagePath = if ($useStorageLocal) { Join-Path -Path $storageModsDir -ChildPath $jarName } else { $null }
    $gameDest = $null
    $storageDest = $null

    if (Test-Path -LiteralPath $gamePath) {
      $gameDest = Move-ToQuarantine -SourcePath $gamePath -DestDir $gameQuarantine -IsDryRun $false -Retries $retryCount -DelayMs $retryDelayMs
    }
    if ($useStorageLocal -and $storagePath -and (Test-Path -LiteralPath $storagePath)) {
      $storageDest = Move-ToQuarantine -SourcePath $storagePath -DestDir $storageQuarantine -IsDryRun $false -Retries $retryCount -DelayMs $retryDelayMs
    }

    if ($null -ne $gameDest -or $null -ne $storageDest) {
      $item = Get-MovedItemByJarName -JarName $jarName -Context $Context
      if ($null -eq $item) {
        $item = [pscustomobject]@{
            JarName = $jarName
            GameSource = $gamePath
            GameQuarantine = $gameDest
            StorageSource = if ($useStorageLocal) { $storagePath } else { $null }
            StorageQuarantine = $storageDest
          }
        $items.Add($item)
      } else {
        if ($gameDest) {
          $item.GameSource = $gamePath
          $item.GameQuarantine = $gameDest
        }
        if ($storageDest) {
          $item.StorageSource = if ($useStorageLocal) { $storagePath } else { $null }
          $item.StorageQuarantine = $storageDest
        }
      }
      $jarNameSet[$jarName] = $true
    } else {
      $item = Get-MovedItemByJarName -JarName $jarName -Context $Context
      if ($null -ne $item -and (-not $jarNameSet.ContainsKey($jarName))) {
        $jarNameSet[$jarName] = $true
      }
    }
  }
}
