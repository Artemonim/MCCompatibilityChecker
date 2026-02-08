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

  function Invoke-WithRetry {
    param(
      [Parameter(Mandatory = $true)]
      [scriptblock]$Action,
      [int]$MaxRetries = $Retries,
      [int]$WaitMs = $DelayMs
    )
    for ($i = 0; $i -le $MaxRetries; $i++) {
      try {
        & $Action
        return $true
      } catch [System.IO.IOException] {
        if ($i -ge $MaxRetries) { throw }
        Start-Sleep -Milliseconds $WaitMs
        continue
      } catch {
        throw
      }
    }
    return $false
  }

  function Find-LegacySourcePath {
    param(
      [Parameter(Mandatory = $false)]
      [AllowEmptyString()]
      [string]$ModsRootDir = "",
      [Parameter(Mandatory = $false)]
      [AllowEmptyString()]
      [string]$LegacyFolderName = "",
      [Parameter(Mandatory = $true)]
      [string]$JarName
    )

    if ([string]::IsNullOrWhiteSpace($ModsRootDir)) { return "" }
    if ([string]::IsNullOrWhiteSpace($LegacyFolderName)) { return "" }
    if ([string]::IsNullOrWhiteSpace($JarName)) { return "" }

    $legacyRoot = Join-Path -Path $ModsRootDir -ChildPath $LegacyFolderName
    if (-not (Test-Path -LiteralPath $legacyRoot)) { return "" }

    try {
      $match = Get-ChildItem -LiteralPath $legacyRoot -Recurse -File -Filter $JarName -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 1
      if ($null -ne $match -and -not [string]::IsNullOrWhiteSpace([string]$match.FullName)) {
        return [string]$match.FullName
      }
    } catch {
      return ""
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
      $effectiveStorageLegacyPath = Find-LegacySourcePath -ModsRootDir $storageModsDir -LegacyFolderName "Legacy" -JarName $jarName
      if ([string]::IsNullOrWhiteSpace($effectiveStorageLegacyPath)) {
        $effectiveStorageLegacyPath = Find-LegacySourcePath -ModsRootDir $storageModsDir -LegacyFolderName "legacy" -JarName $jarName
      }
    }
    $effectiveGameLegacyPath = $gameLegacyPath
    if ([string]::IsNullOrWhiteSpace($effectiveGameLegacyPath) -or -not (Test-Path -LiteralPath $effectiveGameLegacyPath)) {
      $effectiveGameLegacyPath = Find-LegacySourcePath -ModsRootDir $gameModsDir -LegacyFolderName "legacy" -JarName $jarName
    }

    try {
      # * Restore storage first.
      if (-not [string]::IsNullOrWhiteSpace($effectiveStorageLegacyPath) -and $storageTarget) {
        if (Test-Path -LiteralPath $effectiveStorageLegacyPath) {
          if (Test-Path -LiteralPath $storageTarget) {
            Write-Host ("Warning: storage target already exists, leaving legacy copy: {0}" -f $storageTarget) -ForegroundColor Yellow
          } else {
            Invoke-WithRetry -Action { Move-Item -LiteralPath $effectiveStorageLegacyPath -Destination $storageTarget -Force -ErrorAction Stop } -MaxRetries $Retries -WaitMs $DelayMs | Out-Null
            Write-Host ("Restored storage mod: {0}" -f $storageTarget) -ForegroundColor Green
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
          Invoke-WithRetry -Action { Move-Item -LiteralPath $effectiveGameLegacyPath -Destination $gameTarget -Force -ErrorAction Stop } -MaxRetries $Retries -WaitMs $DelayMs | Out-Null
          Write-Host ("Restored game mod: {0}" -f $gameTarget) -ForegroundColor Green
          $restoredThisJar = $true
          $restoredJarNames.Add($jarName) | Out-Null
          continue
        }

        # * Fallback: copy from storage root (preferred) or from storage legacy.
        if ($storageTarget -and (Test-Path -LiteralPath $storageTarget)) {
          Invoke-WithRetry -Action { Copy-Item -LiteralPath $storageTarget -Destination $gameTarget -Force -ErrorAction Stop } -MaxRetries $Retries -WaitMs $DelayMs | Out-Null
          Write-Host ("Restored game mod (copied from storage): {0}" -f $gameTarget) -ForegroundColor Green
          $restoredThisJar = $true
          $restoredJarNames.Add($jarName) | Out-Null
          continue
        }
        if (-not [string]::IsNullOrWhiteSpace($effectiveStorageLegacyPath) -and (Test-Path -LiteralPath $effectiveStorageLegacyPath)) {
          Invoke-WithRetry -Action { Copy-Item -LiteralPath $effectiveStorageLegacyPath -Destination $gameTarget -Force -ErrorAction Stop } -MaxRetries $Retries -WaitMs $DelayMs | Out-Null
          Write-Host ("Restored game mod (copied from storage legacy): {0}" -f $gameTarget) -ForegroundColor Green
          $restoredThisJar = $true
          $restoredJarNames.Add($jarName) | Out-Null
          continue
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
