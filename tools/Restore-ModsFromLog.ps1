# * Restore-ModsFromLog.ps1
# * Restores mods moved to legacy storage based on legacy.log entries.

# * Load shared config
$sharedConfigPath = Join-Path $PSScriptRoot "..\scripts\Shared-Config.ps1"
if (Test-Path $sharedConfigPath) {
    . $sharedConfigPath
}
else {
    Write-Error ("Shared config not found at: {0}" -f $sharedConfigPath)
    exit 1
}

$config = Import-ProjectConfig -StartDir $PSScriptRoot
$ini = $config.Ini

# * Reads from legacy.log (persistent append-only culprit log).
$logPath = Join-Path $config.Root "scripts\legacy.log"
$target1 = Get-IniValue -Ini $ini -Section "Paths" -Key "StorageModsDir" -Default "D:\Установщики игр\MineCraft 1.21\Mods"
$target2 = Get-IniValue -Ini $ini -Section "Paths" -Key "GameModsDir" -Default "$env:APPDATA\.tlauncher\legacy\Minecraft\game\mods"

if (-not (Test-Path $logPath)) {
    Write-Error ("Log file not found at: {0}" -f $logPath)
    exit 1
}

$logContent = Get-Content $logPath
$culpritLines = $logContent | Where-Object { $_ -like "*Moved culprit to storage legacy: *" }

if ($culpritLines.Count -eq 0) {
    Write-Host "No culprits found to restore in the log."
    exit 0
}

Write-Host ("Found {0} culprit(s) to restore." -f $culpritLines.Count)

foreach ($line in $culpritLines) {
    # * Extract path from line
    # * Line format: "Moved culprit to storage legacy: D:\...\file.jar"
    $parts = $line -split "Moved culprit to storage legacy: "
    if ($parts.Count -lt 2) { continue }
    
    $sourcePath = $parts[1].Trim()
    
    if (-not (Test-Path $sourcePath)) {
        Write-Warning ("Source file not found: {0}" -f $sourcePath)
        continue
    }

    $fileName = Split-Path $sourcePath -Leaf
    $dest1 = Join-Path $target1 $fileName
    $dest2 = Join-Path $target2 $fileName

    Write-Host ("Restoring: {0}" -f $fileName)

    try {
        # * Copy to Target 1
        if (-not (Test-Path $target1)) { New-Item -ItemType Directory -Path $target1 -Force | Out-Null }
        Copy-Item -Path $sourcePath -Destination $dest1 -Force
        Write-Host ("  [+] Copied to: {0}" -f $target1)

        # * Copy to Target 2
        if (-not (Test-Path $target2)) { New-Item -ItemType Directory -Path $target2 -Force | Out-Null }
        Copy-Item -Path $sourcePath -Destination $dest2 -Force
        Write-Host ("  [+] Copied to: {0}" -f $target2)

        # * Remove from original location
        Remove-Item -Path $sourcePath -Force
        Write-Host ("  [-] Removed from legacy storage: {0}" -f $sourcePath)
    }
    catch {
        Write-Error ("Failed to restore {0}: {1}" -f $fileName, $_.Exception.Message)
    }
}

Write-Host "Restore process completed."
