# * Shared helpers for moving culprits into legacy folders.

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
    [string]$GameLegacyFolderName = "legacy",
    [Parameter(Mandatory = $false)]
    [string]$StorageLegacyFolderName = "Legacy",
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

  $useStorage = -not [string]::IsNullOrWhiteSpace($StorageModsDir)
  $legacyLog = $LegacyLogPath
  if ([string]::IsNullOrWhiteSpace($legacyLog)) {
    $projectRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath ".."))
    $legacyLog = Join-Path -Path $projectRoot -ChildPath "legacy.log"
  }

  if ($useStorage -and -not [string]::IsNullOrWhiteSpace($StorageSourcePath) -and (Test-Path -LiteralPath $StorageSourcePath)) {
    $storageLegacyRoot = Join-Path -Path $StorageModsDir -ChildPath $StorageLegacyFolderName
    $storageLegacyVersionDir = Join-Path -Path $storageLegacyRoot -ChildPath $MinecraftVersion
    New-DirectoryIfMissing -DirPath $storageLegacyVersionDir
    $destPath = Join-Path -Path $storageLegacyVersionDir -ChildPath $JarName
    if ($StorageTransferMode -eq "Copy") {
      Copy-Item -LiteralPath $StorageSourcePath -Destination $destPath -Force
    } else {
      Move-Item -LiteralPath $StorageSourcePath -Destination $destPath -Force -ErrorAction Stop
    }
    Write-Host ("Moved culprit to storage legacy: {0}" -f $destPath) -ForegroundColor Green
    $legacyLogEntry = "Moved culprit to storage legacy: {0}" -f $destPath
    Add-Content -LiteralPath $legacyLog -Value $legacyLogEntry -ErrorAction SilentlyContinue
    $storageLegacyPath = $destPath
    $storageMoved = $true
  }

  if ($KeepCulpritInGameLegacy) {
    if (-not [string]::IsNullOrWhiteSpace($GameSourcePath) -and (Test-Path -LiteralPath $GameSourcePath)) {
      $gameLegacyRoot = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
      $gameLegacyVersionDir = Join-Path -Path $gameLegacyRoot -ChildPath $MinecraftVersion
      New-DirectoryIfMissing -DirPath $gameLegacyVersionDir
      $destPath = Join-Path -Path $gameLegacyVersionDir -ChildPath $JarName
      if ($GameTransferMode -eq "Copy") {
        Copy-Item -LiteralPath $GameSourcePath -Destination $destPath -Force
      } else {
        Move-Item -LiteralPath $GameSourcePath -Destination $destPath -Force -ErrorAction Stop
      }
      Write-Host ("Moved culprit to game legacy: {0}" -f $destPath) -ForegroundColor Green
      $gameLegacyPath = $destPath
      $gameMoved = $true
    }
  } elseif ($RemoveGameIfNotKeeping) {
    $canRemove = (-not $useStorage) -or (-not $RequireStorageMoveForGameRemoval) -or $storageMoved
    $preferFallbackToGameLegacy = $useStorage -and (-not $storageMoved)
    if ((-not $preferFallbackToGameLegacy) -and $canRemove -and -not [string]::IsNullOrWhiteSpace($GameSourcePath) -and (Test-Path -LiteralPath $GameSourcePath)) {
      Remove-Item -LiteralPath $GameSourcePath -Force -ErrorAction Stop
      $gameMoved = $true
    } elseif (-not [string]::IsNullOrWhiteSpace($GameSourcePath) -and (Test-Path -LiteralPath $GameSourcePath)) {
      # * Safety fallback: if storage legacy copy is unavailable, keep an auditable game-legacy copy
      # * instead of deleting the only remaining culprit artifact.
      $gameLegacyRoot = Join-Path -Path $GameModsDir -ChildPath $GameLegacyFolderName
      $gameLegacyVersionDir = Join-Path -Path $gameLegacyRoot -ChildPath $MinecraftVersion
      New-DirectoryIfMissing -DirPath $gameLegacyVersionDir
      $destPath = Join-Path -Path $gameLegacyVersionDir -ChildPath $JarName
      Move-Item -LiteralPath $GameSourcePath -Destination $destPath -Force -ErrorAction Stop
      Write-Host ("Storage legacy copy is unavailable. Moved culprit to game legacy fallback: {0}" -f $destPath) -ForegroundColor Yellow
      $gameLegacyPath = $destPath
      $gameMoved = $true
    }
  }

  return [pscustomobject]@{
    StorageLegacyPath = $storageLegacyPath
    GameLegacyPath = $gameLegacyPath
    StorageMoved = [bool]$storageMoved
    GameMoved = [bool]$gameMoved
  }
}
