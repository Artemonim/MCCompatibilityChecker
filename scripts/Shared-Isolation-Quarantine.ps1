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
  New-DirectoryIfMissing -DirPath $DestDir
  $destPath = Join-Path -Path $DestDir -ChildPath ([System.IO.Path]::GetFileName($SourcePath))
  for ($i = 0; $i -le $Retries; $i++) {
    try {
      Move-Item -LiteralPath $SourcePath -Destination $destPath -Force -ErrorAction Stop
      return $destPath
    } catch [System.IO.IOException] {
      if ($i -ge $Retries) { throw }
      Start-Sleep -Milliseconds $DelayMs
      continue
    } catch {
      throw
    }
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
  New-DirectoryIfMissing -DirPath $DestDir
  $destPath = Join-Path -Path $DestDir -ChildPath ([System.IO.Path]::GetFileName($SourcePath))
  if ((Test-Path -LiteralPath $destPath) -and (-not $AllowOverwrite)) {
    return ("restore skipped (exists): {0}" -f $destPath)
  }
  Move-Item -LiteralPath $SourcePath -Destination $destPath -Force -ErrorAction Stop
  return $destPath
}

function Get-MovedItemByJarName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarName
  )

  foreach ($item in $movedItems) {
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
    [string]$StorageQuarantine
  )

  $item = Get-MovedItemByJarName -JarName $JarName
  if ($null -eq $item) {
    $item = [pscustomobject]@{
        JarName = $JarName
        GameSource = $null
        GameQuarantine = $null
        StorageSource = $null
        StorageQuarantine = $null
      }
    $movedItems.Add($item)
  }

  if ($PSBoundParameters.ContainsKey("GameSource")) { $item.GameSource = $GameSource }
  if ($PSBoundParameters.ContainsKey("GameQuarantine")) { $item.GameQuarantine = $GameQuarantine }
  if ($PSBoundParameters.ContainsKey("StorageSource")) { $item.StorageSource = $StorageSource }
  if ($PSBoundParameters.ContainsKey("StorageQuarantine")) { $item.StorageQuarantine = $StorageQuarantine }

  $movedJarNameSet[$JarName] = $true
  return $item
}

function Update-QuarantineState {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$DesiredJarNames,
    [Parameter(Mandatory = $false)]
    [string[]]$PinnedJarNames = @()
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

  foreach ($item in $movedItems) {
    if ($null -eq $item) { continue }
    $jarName = [string]$item.JarName
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
    $key = $jarName.ToLowerInvariant()
    if ($desiredSet.ContainsKey($key)) { continue }

    if (-not [string]::IsNullOrWhiteSpace($item.GameQuarantine) -and (Test-Path -LiteralPath $item.GameQuarantine)) {
      $restoreGame = Restore-FromQuarantine -SourcePath $item.GameQuarantine `
        -DestDir $GameModsDir `
        -IsDryRun $false `
        -AllowOverwrite ([bool]$ForceRestore)
      if ($restoreGame -and (-not (Test-Path -LiteralPath $item.GameQuarantine))) {
        $item.GameQuarantine = $null
      }
    }
    if ($useStorage -and -not [string]::IsNullOrWhiteSpace($item.StorageQuarantine) -and (Test-Path -LiteralPath $item.StorageQuarantine)) {
      $restoreStorage = Restore-FromQuarantine -SourcePath $item.StorageQuarantine `
        -DestDir $StorageModsDir `
        -IsDryRun $false `
        -AllowOverwrite ([bool]$ForceRestore)
      if ($restoreStorage -and (-not (Test-Path -LiteralPath $item.StorageQuarantine))) {
        $item.StorageQuarantine = $null
      }
    }

    if ($movedJarNameSet.ContainsKey($jarName)) {
      $null = $movedJarNameSet.Remove($jarName)
    }
  }

  foreach ($key in $desiredSet.Keys) {
    $jarName = $desiredSet[$key]
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }

    $gamePath = Join-Path -Path $GameModsDir -ChildPath $jarName
    $storagePath = if ($useStorage) { Join-Path -Path $StorageModsDir -ChildPath $jarName } else { $null }
    $gameDest = $null
    $storageDest = $null

    if (Test-Path -LiteralPath $gamePath) {
      $gameDest = Move-ToQuarantine -SourcePath $gamePath -DestDir $gameQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
    }
    if ($useStorage -and $storagePath -and (Test-Path -LiteralPath $storagePath)) {
      $storageDest = Move-ToQuarantine -SourcePath $storagePath -DestDir $storageQuarantineDir -IsDryRun $false -Retries $MoveRetryCount -DelayMs $MoveRetryDelayMs
    }

    if ($null -ne $gameDest -or $null -ne $storageDest) {
      $item = Get-MovedItemByJarName -JarName $jarName
      if ($null -eq $item) {
        $item = [pscustomobject]@{
            JarName = $jarName
            GameSource = $gamePath
            GameQuarantine = $gameDest
            StorageSource = if ($useStorage) { $storagePath } else { $null }
            StorageQuarantine = $storageDest
          }
        $movedItems.Add($item)
      } else {
        if ($gameDest) {
          $item.GameSource = $gamePath
          $item.GameQuarantine = $gameDest
        }
        if ($storageDest) {
          $item.StorageSource = if ($useStorage) { $storagePath } else { $null }
          $item.StorageQuarantine = $storageDest
        }
      }
      $movedJarNameSet[$jarName] = $true
    } else {
      $item = Get-MovedItemByJarName -JarName $jarName
      if ($null -ne $item -and (-not $movedJarNameSet.ContainsKey($jarName))) {
        $movedJarNameSet[$jarName] = $true
      }
    }
  }
}
