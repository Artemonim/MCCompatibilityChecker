# * Shared helpers for moving culprits into legacy folders.

$sharedFileOpsPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-FileOps.ps1"
if (-not (Test-Path -LiteralPath $sharedFileOpsPath)) {
  throw ("Shared file operation helpers not found: {0}" -f $sharedFileOpsPath)
}
. $sharedFileOpsPath

function Get-FirstExistingPath {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$Candidates = @()
  )

  foreach ($candidate in $Candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (Test-Path -LiteralPath $candidate) {
      return [string]$candidate
    }
  }
  return ""
}

function Move-CulpritToLegacyAndAppendLog {
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarName,
    [Parameter(Mandatory = $true)]
    [string]$MinecraftVersion,
    [Parameter(Mandatory = $true)]
    [string]$GameModsDir,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$StorageModsDir = "",
    [Parameter(Mandatory = $false)]
    [string]$GameLegacyFolderName = "",
    [Parameter(Mandatory = $false)]
    [string]$StorageLegacyFolderName = "",
    [Parameter(Mandatory = $false)]
    [bool]$KeepCulpritInGameLegacy = $false,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$StorageSourcePath = "",
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$GameSourcePath = "",
    [Parameter(Mandatory = $false)]
    [ValidateSet("Move", "Copy")]
    [string]$StorageTransferMode = "Move",
    [Parameter(Mandatory = $false)]
    [ValidateSet("Move", "Copy")]
    [string]$GameTransferMode = "Move",
    [Parameter(Mandatory = $false)]
    [bool]$RemoveGameIfNotKeeping = $false,
    [Parameter(Mandatory = $false)]
    [bool]$RequireStorageMoveForGameRemoval = $true,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$LegacyLogPath = ""
  )

  $storageLegacyPath = $null
  $gameLegacyPath = $null
  $storageMoved = $false
  $gameMoved = $false

  $resolvedLegacyFolders = Resolve-McccLegacyFolderNames `
    -GameLegacyFolderName $GameLegacyFolderName `
    -StorageLegacyFolderName $StorageLegacyFolderName
  $GameLegacyFolderName = [string]$resolvedLegacyFolders.GameLegacyFolderName
  $StorageLegacyFolderName = [string]$resolvedLegacyFolders.StorageLegacyFolderName

  $useStorage = -not [string]::IsNullOrWhiteSpace($StorageModsDir)
  $legacyLog = $LegacyLogPath
  if ([string]::IsNullOrWhiteSpace($legacyLog)) {
    $projectRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath ".."))
    $legacyLog = Join-Path -Path $projectRoot -ChildPath "legacy.log"
  }

  function Add-LegacyMoveLogEntry {
    param(
      [Parameter(Mandatory = $true)]
      [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    try {
      Add-Content -LiteralPath $legacyLog -Value $Message -ErrorAction Stop
    } catch {
      Write-Verbose ("Failed to append legacy move log entry: {0}" -f $_.Exception.Message)
    }
  }

  if ($useStorage -and -not [string]::IsNullOrWhiteSpace($StorageSourcePath) -and (Test-Path -LiteralPath $StorageSourcePath)) {
    $storageLegacyRoot = Join-Path -Path $StorageModsDir -ChildPath $StorageLegacyFolderName
    $storageLegacyVersionDir = Join-Path -Path $storageLegacyRoot -ChildPath $MinecraftVersion
    $destPath = Join-McccDestinationPath -SourcePath $StorageSourcePath -DestinationDirectory $storageLegacyVersionDir
    if ($StorageTransferMode -eq "Copy") {
      $copyResult = Copy-McccItem -LiteralPath $StorageSourcePath -DestinationPath $destPath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
      $storageMoved = [bool]$copyResult.Performed
    } else {
      $moveResult = Move-McccItem -LiteralPath $StorageSourcePath -DestinationPath $destPath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
      $storageMoved = [bool]$moveResult.Performed
    }
    if ($storageMoved) {
      Write-Host ("Moved culprit to storage legacy: {0}" -f $destPath) -ForegroundColor Green
      $legacyLogEntry = "Moved culprit to storage legacy: {0}" -f $destPath
      Add-LegacyMoveLogEntry -Message $legacyLogEntry
      $storageLegacyPath = $destPath
    }
  }

  if ($KeepCulpritInGameLegacy) {
    if (-not [string]::IsNullOrWhiteSpace($GameSourcePath) -and (Test-Path -LiteralPath $GameSourcePath)) {
      $gameLegacyRoot = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
      $gameLegacyVersionDir = Join-Path -Path $gameLegacyRoot -ChildPath $MinecraftVersion
      $destPath = Join-McccDestinationPath -SourcePath $GameSourcePath -DestinationDirectory $gameLegacyVersionDir
      if ($GameTransferMode -eq "Copy") {
        $copyResult = Copy-McccItem -LiteralPath $GameSourcePath -DestinationPath $destPath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        $gameMoved = [bool]$copyResult.Performed
      } else {
        $moveResult = Move-McccItem -LiteralPath $GameSourcePath -DestinationPath $destPath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
        $gameMoved = [bool]$moveResult.Performed
      }
      if ($gameMoved) {
        Write-Host ("Moved culprit to game legacy: {0}" -f $destPath) -ForegroundColor Green
        $legacyLogEntry = "Moved culprit to game legacy: {0}" -f $destPath
        Add-LegacyMoveLogEntry -Message $legacyLogEntry
        $gameLegacyPath = $destPath
      }
    }
  } elseif ($RemoveGameIfNotKeeping) {
    $canRemove = (-not $useStorage) -or (-not $RequireStorageMoveForGameRemoval) -or $storageMoved
    $preferFallbackToGameLegacy = $useStorage -and (-not $storageMoved)
    if ((-not $preferFallbackToGameLegacy) -and $canRemove -and -not [string]::IsNullOrWhiteSpace($GameSourcePath) -and (Test-Path -LiteralPath $GameSourcePath)) {
      $removeResult = Remove-McccItem -LiteralPath $GameSourcePath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
      $gameMoved = [bool]$removeResult.Performed
    } elseif (-not [string]::IsNullOrWhiteSpace($GameSourcePath) -and (Test-Path -LiteralPath $GameSourcePath)) {
      # * Safety fallback: if storage legacy copy is unavailable, keep an auditable game-legacy copy
      # * instead of deleting the only remaining culprit artifact.
      $gameLegacyRoot = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
      $gameLegacyVersionDir = Join-Path -Path $gameLegacyRoot -ChildPath $MinecraftVersion
      $destPath = Join-McccDestinationPath -SourcePath $GameSourcePath -DestinationDirectory $gameLegacyVersionDir
      $moveFallbackResult = Move-McccItem -LiteralPath $GameSourcePath -DestinationPath $destPath -DryRun $false -Overwrite $true -RetryCount 0 -RetryDelayMs 0
      if ($moveFallbackResult.Performed) {
        Write-Host ("Storage legacy copy is unavailable. Moved culprit to game legacy fallback: {0}" -f $destPath) -ForegroundColor Yellow
        $legacyLogEntry = "Storage legacy copy is unavailable. Moved culprit to game legacy fallback: {0}" -f $destPath
        Add-LegacyMoveLogEntry -Message $legacyLogEntry
        $gameLegacyPath = $destPath
        $gameMoved = $true
      }
    }
  }

  return [pscustomobject]@{
    StorageLegacyPath = $storageLegacyPath
    GameLegacyPath = $gameLegacyPath
    StorageMoved = [bool]$storageMoved
    GameMoved = [bool]$gameMoved
  }
}
