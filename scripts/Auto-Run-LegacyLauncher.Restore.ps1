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
    [int]$DelayMs = 750
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

  $hadFailures = $false
  foreach ($m in $CulpritMoves) {
    if ($null -eq $m) { continue }

    $jarName = [string]$m.JarName
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }

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

    try {
      # * Restore storage first.
      if (-not [string]::IsNullOrWhiteSpace($storageLegacyPath) -and $storageTarget) {
        if (Test-Path -LiteralPath $storageLegacyPath) {
          if (Test-Path -LiteralPath $storageTarget) {
            Write-Host ("Warning: storage target already exists, leaving legacy copy: {0}" -f $storageTarget) -ForegroundColor Yellow
          } else {
            Invoke-WithRetry -Action { Move-Item -LiteralPath $storageLegacyPath -Destination $storageTarget -Force -ErrorAction Stop } -MaxRetries $Retries -WaitMs $DelayMs | Out-Null
            Write-Host ("Restored storage mod: {0}" -f $storageTarget) -ForegroundColor Green
          }
        }
      }

      # * Restore game mod (prefer game-legacy copy if present).
      if ($gameTarget) {
        if (Test-Path -LiteralPath $gameTarget) {
          # * Already restored (manually or by other logic).
          continue
        }

        if (-not [string]::IsNullOrWhiteSpace($gameLegacyPath) -and (Test-Path -LiteralPath $gameLegacyPath)) {
          Invoke-WithRetry -Action { Move-Item -LiteralPath $gameLegacyPath -Destination $gameTarget -Force -ErrorAction Stop } -MaxRetries $Retries -WaitMs $DelayMs | Out-Null
          Write-Host ("Restored game mod: {0}" -f $gameTarget) -ForegroundColor Green
          continue
        }

        # * Fallback: copy from storage root (preferred) or from storage legacy.
        if ($storageTarget -and (Test-Path -LiteralPath $storageTarget)) {
          Invoke-WithRetry -Action { Copy-Item -LiteralPath $storageTarget -Destination $gameTarget -Force -ErrorAction Stop } -MaxRetries $Retries -WaitMs $DelayMs | Out-Null
          Write-Host ("Restored game mod (copied from storage): {0}" -f $gameTarget) -ForegroundColor Green
          continue
        }
        if (-not [string]::IsNullOrWhiteSpace($storageLegacyPath) -and (Test-Path -LiteralPath $storageLegacyPath)) {
          Invoke-WithRetry -Action { Copy-Item -LiteralPath $storageLegacyPath -Destination $gameTarget -Force -ErrorAction Stop } -MaxRetries $Retries -WaitMs $DelayMs | Out-Null
          Write-Host ("Restored game mod (copied from storage legacy): {0}" -f $gameTarget) -ForegroundColor Green
          continue
        }

        Write-Host ("Warning: could not restore game mod '{0}' (no legacy/source copy found)." -f $jarName) -ForegroundColor Yellow
      }
    } catch {
      $hadFailures = $true
      Write-Host ("Error while restoring '{0}': {1}" -f $jarName, $_.Exception.Message) -ForegroundColor Red
    }
  }

  return (-not $hadFailures)
}
