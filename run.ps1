<#
.SYNOPSIS
Project entrypoint for MCCompatibilityChecker.

.DESCRIPTION
Runs scripts\Auto-Run-LegacyLauncher.ps1 and forwards all arguments.
This automation script manages the lifecycle of Legacy Launcher, detects crashes,
and runs mod compatibility checks and isolation to fix issues.

Configuration:
  Uses config.ini and optional config.local.ini in the repository root
  to configure default paths (LauncherExePath, LogPath).

Commonly used parameters:
  -LauncherExePath <path>  Path to Legacy Launcher executable.
  -NoLegacy               Ignore legacy folders (Check-Mod-Compatibility).
  -GameLegacy             Use game-side legacy folders for isolation.
  -DryRun                 Print planned actions without executing them.
  -Verbose                Enable detailed logs (saved to MCCC.log and console).
  -UseLinearIsolation     Use linear search instead of binary for isolation.
  -OutcomeTimeoutSeconds  How long to wait for a crash after clicking Play.
  -Profile <name>         Load advanced overrides from [Profile:<name>] in config.ini.

.PARAMETER Help
Show concise colored help for the most common parameters.

.PARAMETER HelpFull
Show the full technical help with all available parameters from the underlying script.

.PARAMETER RemainingArgs
Any additional arguments to be forwarded to the automation script.
#>

[CmdletBinding(PositionalBinding=$false)]
param(
  # * Show concise colored help and exit.
  [switch]$Help,

  # * Show full technical help and exit.
  [switch]$HelpFull,

  # * Arguments to be forwarded to the underlying script.
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArgs
)

$scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "scripts\Auto-Run-LegacyLauncher.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
  throw ("Entrypoint script not found: {0}" -f $scriptPath)
}

if ($Help) {
  Write-Host "`nMCCompatibilityChecker - Concise Help" -ForegroundColor Cyan -FontWeight Bold
  Write-Host "--------------------------------------" -ForegroundColor Cyan

  Write-Host "Setup Tip:" -ForegroundColor White
  Write-Host "  Create 'config.local.ini' or edit 'config.ini' in the repo root to set your custom paths to mods." -ForegroundColor Gray

  Write-Host "Usage:" -ForegroundColor White
  Write-Host "  .\run.ps1 [-LauncherExePath <path>] [-NoLegacy] [-GameLegacy] [-DryRun] [-Verbose] [-HelpFull]`n" -ForegroundColor Gray

  Write-Host "Commonly Used Parameters:" -ForegroundColor White
  Write-Host "  -LauncherExePath <path> " -NoNewline -ForegroundColor Yellow
  Write-Host ": Path to Legacy Launcher executable." -ForegroundColor Gray

  Write-Host "  -NoLegacy               " -NoNewline -ForegroundColor Yellow
  Write-Host ": Ignore legacy folders in storage." -ForegroundColor Gray

  Write-Host "  -GameLegacy             " -NoNewline -ForegroundColor Yellow
  Write-Host ": Use game-side legacy folders for isolation." -ForegroundColor Gray

  Write-Host "  -DryRun                 " -NoNewline -ForegroundColor Yellow
  Write-Host ": Simulate process without clicking or deleting." -ForegroundColor Gray

  Write-Host "  -Verbose                " -NoNewline -ForegroundColor Yellow
  Write-Host ": Enable detailed logging to console and MCCC.log." -ForegroundColor Gray

  Write-Host "  -UseLinearIsolation     " -NoNewline -ForegroundColor Yellow
  Write-Host ": Use linear search for isolation (slower but simple)." -ForegroundColor Gray

  Write-Host "  -Profile <name>         " -NoNewline -ForegroundColor Yellow
  Write-Host ": Load advanced overrides from config.ini profile." -ForegroundColor Gray

  Write-Host "  -HelpFull               " -NoNewline -ForegroundColor Cyan
  Write-Host ": Show the complete (very long) technical help.`n" -ForegroundColor Gray
  return
}

if ($HelpFull) {
  & $scriptPath -Help @RemainingArgs
  exit $LASTEXITCODE
}

$forwardCommon = @{}
if ($PSBoundParameters.ContainsKey("Verbose")) {
  $forwardCommon["Verbose"] = $true
}
if ($PSBoundParameters.ContainsKey("Debug")) {
  $forwardCommon["Debug"] = $true
}

if ($null -eq $RemainingArgs) {
  $RemainingArgs = @()
}

& $scriptPath @forwardCommon @RemainingArgs
exit $LASTEXITCODE

