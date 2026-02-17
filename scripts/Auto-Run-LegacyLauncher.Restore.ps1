$sharedFileOpsPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-FileOps.ps1"
if (-not (Test-Path -LiteralPath $sharedFileOpsPath)) {
  throw ("Shared file operation helpers not found: {0}" -f $sharedFileOpsPath)
}
. $sharedFileOpsPath
 
function Restore-IsolationCulpritMod {
  <#
  .SYNOPSIS
  Restores mods isolated by Isolate-Incompatible-Mod.ps1 back to game/storage roots.

  .DESCRIPTION
  Best-effort restore intended for "stop by user choice" flows.
  - Moves storage legacy copy back to storage root (when available).
  - Restores game copy from game legacy if present; otherwise copies from storage (legacy or root).
  #>
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$CulpritMoves,
    [Parameter(Mandatory = $false)]
    [int]$Retries = 10,
    [Parameter(Mandatory = $false)]
    [int]$DelayMs = 750,
    [Parameter(Mandatory = $false)]
    [switch]$ReturnDetails
  )

  function Find-LegacySourcePath {
    param(
      [Parameter(Mandatory = $false)]
      [AllowEmptyString()]
      [string]$ModsRootDir = "",
      [Parameter(Mandatory = $false)]
      [AllowEmptyCollection()]
      [string[]]$LegacyFolderNames = @(),
      [Parameter(Mandatory = $true)]
      [string]$JarName
    )

    if ([string]::IsNullOrWhiteSpace($ModsRootDir)) { return "" }
    if (-not $LegacyFolderNames -or $LegacyFolderNames.Count -eq 0) { return "" }
    if ([string]::IsNullOrWhiteSpace($JarName)) { return "" }

    foreach ($legacyFolderName in @($LegacyFolderNames)) {
      if ([string]::IsNullOrWhiteSpace($legacyFolderName)) { continue }
      $legacyRoot = Join-Path -Path $ModsRootDir -ChildPath $legacyFolderName
      if (-not (Test-Path -LiteralPath $legacyRoot)) { continue }

      try {
        $match = Get-ChildItem -LiteralPath $legacyRoot -Recurse -File -Filter $JarName -ErrorAction SilentlyContinue |
          Sort-Object -Property LastWriteTime -Descending |
          Select-Object -First 1
        if ($null -ne $match -and -not [string]::IsNullOrWhiteSpace([string]$match.FullName)) {
          return [string]$match.FullName
        }
      } catch {
        continue
      }
    }

    return ""
  }

  $hadFailures = $false
  $restoredJarNames = New-Object System.Collections.Generic.List[string]
  $failedJarNames = New-Object System.Collections.Generic.List[string]
  foreach ($m in $CulpritMoves) {
    if ($null -eq $m) { continue }

    $jarName = [string]$m.JarName
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
    $restoredThisJar = $false

    $gameModsDir = [string]$m.GameModsDir
    $storageModsDir = [string]$m.StorageModsDir
    $storageLegacyPath = [string]$m.StorageLegacyPath
    $gameLegacyPath = [string]$m.GameLegacyPath

    $storageTarget = $null
    if (-not [string]::IsNullOrWhiteSpace($storageModsDir)) {
      $storageTarget = Join-Path -Path $storageModsDir -ChildPath $jarName
    }
    $gameTarget = $null
    if (-not [string]::IsNullOrWhiteSpace($gameModsDir)) {
      $gameTarget = Join-Path -Path $gameModsDir -ChildPath $jarName
    }

    # * If explicit legacy paths are missing, try to discover likely source copies by jar name.
    $effectiveStorageLegacyPath = $storageLegacyPath
    if ([string]::IsNullOrWhiteSpace($effectiveStorageLegacyPath) -or -not (Test-Path -LiteralPath $effectiveStorageLegacyPath)) {
      $storageLegacyCandidates = @(Get-McccLegacyFolderCandidates -Role "StorageLegacy")
      $effectiveStorageLegacyPath = Find-LegacySourcePath -ModsRootDir $storageModsDir -LegacyFolderNames $storageLegacyCandidates -JarName $jarName
    }
    $effectiveGameLegacyPath = $gameLegacyPath
    if ([string]::IsNullOrWhiteSpace($effectiveGameLegacyPath) -or -not (Test-Path -LiteralPath $effectiveGameLegacyPath)) {
      $gameLegacyCandidates = @(Get-McccLegacyFolderCandidates -Role "GameLegacy")
      $effectiveGameLegacyPath = Find-LegacySourcePath -ModsRootDir $gameModsDir -LegacyFolderNames $gameLegacyCandidates -JarName $jarName
    }

    try {
      # * Restore storage first.
      if (-not [string]::IsNullOrWhiteSpace($effectiveStorageLegacyPath) -and $storageTarget) {
        if (Test-Path -LiteralPath $effectiveStorageLegacyPath) {
          if (Test-Path -LiteralPath $storageTarget) {
            Write-Host ("Warning: storage target already exists, leaving legacy copy: {0}" -f $storageTarget) -ForegroundColor Yellow
          } else {
            $moveStorageResult = Move-McccItem -LiteralPath $effectiveStorageLegacyPath -DestinationPath $storageTarget -DryRun $false -Overwrite $true -RetryCount $Retries -RetryDelayMs $DelayMs
            if ($moveStorageResult.Performed) {
              Write-Host ("Restored storage mod: {0}" -f $storageTarget) -ForegroundColor Green
            }
          }
        }
      }

      # * Restore game mod (prefer game-legacy copy if present).
      if ($gameTarget) {
        if (Test-Path -LiteralPath $gameTarget) {
          # * Already restored (manually or by other logic).
          $restoredThisJar = $true
          $restoredJarNames.Add($jarName) | Out-Null
          continue
        }

        if (-not [string]::IsNullOrWhiteSpace($effectiveGameLegacyPath) -and (Test-Path -LiteralPath $effectiveGameLegacyPath)) {
          $moveGameResult = Move-McccItem -LiteralPath $effectiveGameLegacyPath -DestinationPath $gameTarget -DryRun $false -Overwrite $true -RetryCount $Retries -RetryDelayMs $DelayMs
          if ($moveGameResult.Performed) {
            Write-Host ("Restored game mod: {0}" -f $gameTarget) -ForegroundColor Green
            $restoredThisJar = $true
            $restoredJarNames.Add($jarName) | Out-Null
            continue
          }
        }

        # * Fallback: copy from storage root (preferred) or from storage legacy.
        if ($storageTarget -and (Test-Path -LiteralPath $storageTarget)) {
          $copyStorageResult = Copy-McccItem -LiteralPath $storageTarget -DestinationPath $gameTarget -DryRun $false -Overwrite $true -RetryCount $Retries -RetryDelayMs $DelayMs
          if ($copyStorageResult.Performed) {
            Write-Host ("Restored game mod (copied from storage): {0}" -f $gameTarget) -ForegroundColor Green
            $restoredThisJar = $true
            $restoredJarNames.Add($jarName) | Out-Null
            continue
          }
        }
        if (-not [string]::IsNullOrWhiteSpace($effectiveStorageLegacyPath) -and (Test-Path -LiteralPath $effectiveStorageLegacyPath)) {
          $copyLegacyResult = Copy-McccItem -LiteralPath $effectiveStorageLegacyPath -DestinationPath $gameTarget -DryRun $false -Overwrite $true -RetryCount $Retries -RetryDelayMs $DelayMs
          if ($copyLegacyResult.Performed) {
            Write-Host ("Restored game mod (copied from storage legacy): {0}" -f $gameTarget) -ForegroundColor Green
            $restoredThisJar = $true
            $restoredJarNames.Add($jarName) | Out-Null
            continue
          }
        }

        Write-Host ("Warning: could not restore game mod '{0}' (no legacy/source copy found)." -f $jarName) -ForegroundColor Yellow
        $failedJarNames.Add($jarName) | Out-Null
      } elseif ($storageTarget -and (Test-Path -LiteralPath $storageTarget)) {
        $restoredThisJar = $true
      }
    } catch {
      $hadFailures = $true
      Write-Host ("Error while restoring '{0}': {1}" -f $jarName, $_.Exception.Message) -ForegroundColor Red
      $failedJarNames.Add($jarName) | Out-Null
      continue
    }

    if ($restoredThisJar) {
      $restoredJarNames.Add($jarName) | Out-Null
    } elseif (-not ($failedJarNames -contains $jarName)) {
      $failedJarNames.Add($jarName) | Out-Null
    }
  }

  if ($ReturnDetails) {
    return [pscustomobject]@{
      Success = (-not $hadFailures) -and ($failedJarNames.Count -eq 0)
      RestoredJarNames = @($restoredJarNames | Sort-Object -Unique)
      FailedJarNames = @($failedJarNames | Sort-Object -Unique)
    }
  }

  return (-not $hadFailures)
}
