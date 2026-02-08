<#
.SYNOPSIS
Runs PSScriptAnalyzer for PowerShell scripts in this repository.

.DESCRIPTION
When no paths are provided, scans all *.ps1 files under the repo root.
You can pass files or folders as arguments; folders are scanned recursively.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
  # * Skip localization asset checks.
  [switch]$NoLocales,
  # * Optional file or directory paths to analyze (defaults to repo root).
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Path = @()
)

$sharedLocalizationPath = Join-Path -Path $PSScriptRoot -ChildPath "scripts\Shared-Localization.ps1"
if (-not (Test-Path -LiteralPath $sharedLocalizationPath)) {
  throw ("Shared localization helpers not found: {0}" -f $sharedLocalizationPath)
}
. $sharedLocalizationPath
Initialize-McccLocalization -StartDir $PSScriptRoot | Out-Null
Enable-McccConsoleLocalization

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# * Configuration.
$ScriptPattern = "*.ps1"
$ExitCodeOnFindings = 1
$ExitCodeOnErrors = 2
$WriteSummary = $true

$repoRoot = $PSScriptRoot

function Resolve-AnalyzerTarget {
  param(
    [AllowEmptyCollection()]
    [string[]]$InputPaths,
    [Parameter(Mandatory = $true)]
    [string]$DefaultRoot
  )

  $targets = New-Object System.Collections.Generic.List[string]
  if (-not $InputPaths -or $InputPaths.Count -eq 0) {
    $targets.Add($DefaultRoot) | Out-Null
    return ,@($targets.ToArray())
  }

  foreach ($entry in $InputPaths) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    if (-not (Test-Path -LiteralPath $entry)) {
      Write-Warning ("Path not found: {0}" -f $entry)
      continue
    }
    $item = Get-Item -LiteralPath $entry -ErrorAction Stop
    $targets.Add($item.FullName) | Out-Null
  }

  return ,@($targets.ToArray())
}

function Get-ScriptFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath
  )

  $item = Get-Item -LiteralPath $TargetPath -ErrorAction Stop
  if ($item.PSIsContainer) {
    $files = Get-ChildItem -LiteralPath $item.FullName -Filter $ScriptPattern -File -Recurse -ErrorAction SilentlyContinue
    if (-not $files -or $files.Count -eq 0) { return @() }
    return ,@($files.FullName)
  }

  if ($item.Extension -ne ".ps1") {
    Write-Warning ("Skipping non-PowerShell file: {0}" -f $item.FullName)
    return @()
  }

  return ,@($item.FullName)
}

try {
  Import-Module -Name "PSScriptAnalyzer" -ErrorAction Stop
}
catch {
  Write-Error (
    "Failed to activate PSScriptAnalyzer module. Fix: Install-Module PSScriptAnalyzer -Scope CurrentUser; " +
    "then restart PowerShell and run .\checker.ps1 again. Details: {0}" -f $_.Exception.Message
  )
  exit $ExitCodeOnErrors
}

$analyzerCommand = Get-Command -Name "Invoke-ScriptAnalyzer" -ErrorAction SilentlyContinue
if (-not $analyzerCommand) {
  Write-Error (
    "Invoke-ScriptAnalyzer command is unavailable after importing PSScriptAnalyzer. " +
    "Fix: Update-Module PSScriptAnalyzer or reinstall it (Install-Module PSScriptAnalyzer -Scope CurrentUser)."
  )
  exit $ExitCodeOnErrors
}

$targets = Resolve-AnalyzerTarget -InputPaths $Path -DefaultRoot $repoRoot
$scriptFiles = New-Object System.Collections.Generic.List[string]
foreach ($target in $targets) {
  $items = Get-ScriptFile -TargetPath $target
  foreach ($file in $items) {
    $scriptFiles.Add($file) | Out-Null
  }
}

$uniqueFiles = @($scriptFiles.ToArray() | Sort-Object -Unique)
if (-not $uniqueFiles -or $uniqueFiles.Count -eq 0) {
  Write-Warning "No PowerShell scripts found to analyze."
  exit 0
}

$findings = New-Object System.Collections.Generic.List[object]
$hadAnalyzerError = $false
$localeValidationFailed = $false
foreach ($file in $uniqueFiles) {
  try {
    $settingsPath = Join-Path -Path $repoRoot -ChildPath "PSScriptAnalyzerSettings.psd1"
    $invokeParams = @{
        Path = $file
        ErrorAction = "Stop"
    }
    if (Test-Path -LiteralPath $settingsPath) {
        $invokeParams["Settings"] = $settingsPath
    }

    $result = Invoke-ScriptAnalyzer @invokeParams
    if ($result) {
      foreach ($entry in $result) {
        $findings.Add($entry) | Out-Null
      }
    }
  } catch {
    $hadAnalyzerError = $true
    Write-Warning ("Analyzer failed for {0}: {1}" -f $file, $_.Exception.Message)
  }
}

if (-not $NoLocales) {
  $localeCheckerPath = Join-Path -Path $repoRoot -ChildPath "tools\Check-Localization.py"
  if (-not (Test-Path -LiteralPath $localeCheckerPath)) {
    $hadAnalyzerError = $true
    Write-Warning ("Localization checker not found: {0}" -f $localeCheckerPath)
  } else {
    $pythonExe = Get-Command -Name "python" -ErrorAction SilentlyContinue
    $pythonArgs = @()
    if ($null -eq $pythonExe) {
      $pythonExe = Get-Command -Name "py" -ErrorAction SilentlyContinue
      if ($null -ne $pythonExe) {
        $pythonArgs += "-3"
      }
    }

    if ($null -eq $pythonExe) {
      $hadAnalyzerError = $true
      Write-Warning "Python runtime was not found (tried: python, py). Use -NoLocales to skip localization checks."
    } else {
      Write-Output "Running localization checks..."
      try {
        & $pythonExe.Source @pythonArgs $localeCheckerPath
        $localeExitCode = $LASTEXITCODE
      } catch {
        $hadAnalyzerError = $true
        $localeExitCode = $ExitCodeOnErrors
        Write-Warning ("Localization checker execution failed: {0}" -f $_.Exception.Message)
      }

      if ($localeExitCode -eq 1) {
        $localeValidationFailed = $true
      } elseif ($localeExitCode -ne 0) {
        $hadAnalyzerError = $true
        Write-Warning ("Localization checker failed with exit code {0}" -f $localeExitCode)
      }
    }
  }
}

if ($findings.Count -gt 0) {
  $findings |
    Sort-Object -Property ScriptName, Line, RuleName |
    Write-Output
}

if ($WriteSummary) {
  Write-Output ("Analyzed scripts: {0}" -f $uniqueFiles.Count)
  if ($findings.Count -gt 0) {
    foreach ($group in ($findings | Group-Object -Property Severity | Sort-Object -Property Name)) {
      Write-Output ("Summary: {0} = {1}" -f $group.Name, $group.Count)
    }
  } else {
    Write-Output "No ScriptAnalyzer findings."
  }
  if ($NoLocales) {
    Write-Output "Localization check: skipped (-NoLocales)."
  } elseif ($localeValidationFailed) {
    Write-Output "Localization check: validation failed."
  } elseif (-not $hadAnalyzerError) {
    Write-Output "Localization check: passed."
  }
  if ($hadAnalyzerError) {
    Write-Warning "One or more checks failed to execute."
  }
}

if ($hadAnalyzerError) { exit $ExitCodeOnErrors }
if ($localeValidationFailed -or $findings.Count -gt 0) { exit $ExitCodeOnFindings }
exit 0
