# * Restore-ModsFromLog.ps1
# * Restores mods moved to storage/game legacy based on legacy.log entries.

[CmdletBinding()]
param(
    # * Optional: restore only entries at or after this timestamp.
    [Parameter(Mandatory = $false)]
    [datetime]$SinceTimestamp = [datetime]::MinValue,

    # * Optional: avoid terminating the caller; sets $LASTEXITCODE instead.
    [Parameter(Mandatory = $false)]
    [switch]$NoExit
)

$sharedLocalizationPath = Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\Shared-Localization.ps1"
if (-not (Test-Path -LiteralPath $sharedLocalizationPath)) {
    throw ("Shared localization helpers not found: {0}" -f $sharedLocalizationPath)
}
. $sharedLocalizationPath
Initialize-McccLocalization -StartDir $PSScriptRoot | Out-Null
Enable-McccConsoleLocalization

function Complete-Restore {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,
        [Parameter(Mandatory = $false)]
        [switch]$NoExit
    )

    $global:LASTEXITCODE = $ExitCode
    if ($NoExit) { return }
    exit $ExitCode
}

function ConvertTo-LegacyLogPathValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$PathValue = ""
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
    $normalized = [string]$PathValue
    $normalized = $normalized.Trim()
    while ($normalized.Length -ge 2 -and (
        ($normalized.StartsWith("'") -and $normalized.EndsWith("'")) -or
        ($normalized.StartsWith('"') -and $normalized.EndsWith('"'))
    )) {
        $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
    }
    return $normalized
}

function Get-LegacyLogMoveInfo {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $text = [string]$Line

    $patterns = @(
        [pscustomobject]@{
            Kind = "storage"
            Pattern = "Moved culprit to storage legacy:\s*(?<path>.+)$"
        },
        [pscustomobject]@{
            Kind = "game"
            Pattern = "Moved culprit to game legacy:\s*(?<path>.+)$"
        },
        [pscustomobject]@{
            Kind = "game"
            Pattern = "Moved culprit to game legacy fallback:\s*(?<path>.+)$"
        }
    )

    foreach ($entry in @($patterns)) {
        $m = [regex]::Match($text, [string]$entry.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) { continue }
        $sourcePath = ConvertTo-LegacyLogPathValue -PathValue ([string]$m.Groups["path"].Value)
        if ([string]::IsNullOrWhiteSpace($sourcePath)) { continue }
        return [pscustomobject]@{
            Kind = [string]$entry.Kind
            SourcePath = $sourcePath
        }
    }

    return $null
}

# * Load shared config.
$sharedConfigPath = Join-Path $PSScriptRoot "..\scripts\Shared-Config.ps1"
if (Test-Path -LiteralPath $sharedConfigPath) {
    . $sharedConfigPath
} else {
    Write-Error ("Shared config not found at: {0}" -f $sharedConfigPath)
    Complete-Restore -ExitCode 1 -NoExit:$NoExit
    return
}

# * Load shared restore helper.
$restoreHelperPath = Join-Path $PSScriptRoot "..\scripts\Auto-Run-LegacyLauncher.Restore.ps1"
if (Test-Path -LiteralPath $restoreHelperPath) {
    . $restoreHelperPath
} else {
    Write-Error ("Warning: restore script not found: {0}" -f $restoreHelperPath)
    Complete-Restore -ExitCode 1 -NoExit:$NoExit
    return
}

if (-not (Get-Command -Name Restore-IsolationCulpritMod -ErrorAction SilentlyContinue)) {
    Write-Error ("Warning: auto-restore failed: {0}" -f $restoreHelperPath)
    Complete-Restore -ExitCode 1 -NoExit:$NoExit
    return
}

$config = Import-ProjectConfig -StartDir $PSScriptRoot
$ini = $config.Ini

# * Reads from legacy.log (persistent append-only culprit log).
$logPath = Join-Path $config.Root "legacy.log"
$storageModsDir = Get-IniValue -Ini $ini -Section "Paths" -Key "StorageModsDir" -Default "D:\Установщики игр\MineCraft 1.21\Mods"
$gameModsDir = Get-IniValue -Ini $ini -Section "Paths" -Key "GameModsDir" -Default "$env:APPDATA\.tlauncher\legacy\Minecraft\game\mods"

# * Keep restore deterministic when StorageModsDir is intentionally empty in config.
if ([string]::IsNullOrWhiteSpace($storageModsDir) -and -not [string]::IsNullOrWhiteSpace($gameModsDir)) {
    $storageModsDir = $gameModsDir
}

if (-not (Test-Path -LiteralPath $logPath)) {
    Write-Error ("Log file not found at: {0}" -f $logPath)
    Complete-Restore -ExitCode 1 -NoExit:$NoExit
    return
}

$logContent = Get-Content -LiteralPath $logPath -ErrorAction Stop
$timestampPattern = '^\s*\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s*$'
$currentTimestamp = [datetime]::MinValue
$effectiveSinceTimestamp = $SinceTimestamp
if ($SinceTimestamp -ne [datetime]::MinValue) {
    $effectiveSinceTimestamp = [datetime]::ParseExact($SinceTimestamp.ToString("yyyy-MM-dd HH:mm:ss"), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
}
if ($effectiveSinceTimestamp -ne [datetime]::MinValue) {
    Write-Host ("Filtering legacy log entries after: {0}" -f $effectiveSinceTimestamp.ToString("yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
}

$movesByJar = @{}
foreach ($line in @($logContent)) {
    $textLine = [string]$line
    if ($textLine -match $timestampPattern) {
        try {
            $currentTimestamp = [datetime]::ParseExact($textLine.Trim(), "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            $currentTimestamp = [datetime]::MinValue
        }
        continue
    }

    if ([string]::IsNullOrWhiteSpace($textLine)) { continue }

    $moveInfo = Get-LegacyLogMoveInfo -Line $textLine
    if ($null -eq $moveInfo) { continue }

    if ($effectiveSinceTimestamp -ne [datetime]::MinValue) {
        if ($currentTimestamp -eq [datetime]::MinValue) { continue }
        if ($currentTimestamp -lt $effectiveSinceTimestamp) { continue }
    }

    $sourcePath = [string]$moveInfo.SourcePath
    $jarName = [System.IO.Path]::GetFileName($sourcePath)
    if ([string]::IsNullOrWhiteSpace($jarName) -or (-not $jarName.EndsWith(".jar", [System.StringComparison]::OrdinalIgnoreCase))) {
        continue
    }

    $jarKey = $jarName.ToLowerInvariant()
    if (-not $movesByJar.ContainsKey($jarKey)) {
        $movesByJar[$jarKey] = [pscustomobject]@{
            JarName = $jarName
            GameModsDir = $gameModsDir
            StorageModsDir = $storageModsDir
            StorageLegacyPath = ""
            GameLegacyPath = ""
            Minecraft = "unknown"
            KeepCulpritInGameLegacy = $true
            CrashEvidenceKey = ""
            Stage = "interrupt-auto-restore"
        }
    }

    if ([string]$moveInfo.Kind -eq "storage") {
        $movesByJar[$jarKey].StorageLegacyPath = $sourcePath
    } elseif ([string]$moveInfo.Kind -eq "game") {
        $movesByJar[$jarKey].GameLegacyPath = $sourcePath
    }
}

$culpritMoves = @($movesByJar.Values | Sort-Object -Property JarName)
if ($culpritMoves.Count -eq 0) {
    if ($effectiveSinceTimestamp -ne [datetime]::MinValue) {
        Write-Host ("No culprits found to restore in the log after {0}." -f $effectiveSinceTimestamp.ToString("yyyy-MM-dd HH:mm:ss"))
    } else {
        Write-Host "No culprits found to restore in the log."
    }
    Complete-Restore -ExitCode 0 -NoExit:$NoExit
    return
}

Write-Host ("Found {0} culprit(s) to restore." -f $culpritMoves.Count)
$restoreDetails = Restore-IsolationCulpritMod -CulpritMoves $culpritMoves -ReturnDetails

if ($null -eq $restoreDetails) {
    Write-Error ("Warning: auto-restore failed: {0}" -f $restoreHelperPath)
    Complete-Restore -ExitCode 1 -NoExit:$NoExit
    return
}

$failedJarNames = @($restoreDetails.FailedJarNames)
$failedCount = $failedJarNames.Count

if ($failedCount -gt 0) {
    $failedLabel = if ($failedJarNames.Count -gt 0) { $failedJarNames -join ", " } else { [string]$failedCount }
    Write-Warning ("Warning: auto-restore failed: {0}" -f $failedLabel)
}

Write-Host "Restore process completed."
$exitCode = if ([bool]$restoreDetails.Success) { 0 } else { 1 }
Complete-Restore -ExitCode $exitCode -NoExit:$NoExit
return
