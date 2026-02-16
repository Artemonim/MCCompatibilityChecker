<#
.SYNOPSIS
Validates repository scripts and quality checks.

.DESCRIPTION
Thin CLI entry point for the project checker. It forwards all execution logic
to `checker-core.ps1` and keeps user-facing help in one place.

Checks performed by the core:
- PSScriptAnalyzer over one or many PowerShell paths.
- Localization asset validation via `tools/Check-Localization.py`.
- Pester tests (with AV-sensitive tests excluded by default).

By default, when no paths are provided, all `*.ps1` files under repo root are
analyzed.

.PARAMETER NoLocales
Skips localization asset checks.

.PARAMETER NoPester
Skips Pester tests.

.PARAMETER PesterPath
Path to Pester tests. Relative paths are resolved from repo root.
Default: `tests`.

.PARAMETER IncludeAvSensitivePester
Includes Pester tests tagged as `AvSensitive`.
By default these tests are excluded.

.PARAMETER Path
Optional file or directory paths to analyze.
If omitted, the checker scans the repository root recursively.

.EXAMPLE
.\checker.ps1

Runs full checks for the repository:
ScriptAnalyzer + localization validation + Pester.

.EXAMPLE
.\checker.ps1 -NoLocales

Runs checks without localization validation.

.EXAMPLE
.\checker.ps1 -NoPester

Runs checks without Pester.

.EXAMPLE
.\checker.ps1 -NoLocales -NoPester

Runs only PSScriptAnalyzer checks.

.EXAMPLE
.\checker.ps1 -PesterPath .\tests\unit

Runs Pester from a custom relative folder.

.EXAMPLE
.\checker.ps1 -IncludeAvSensitivePester

Runs Pester including tests tagged with `AvSensitive`.

.EXAMPLE
.\checker.ps1 .\scripts .\tools\Analyze-JarDependencies.ps1

Checks only the provided folder/file targets.

.NOTES
Exit codes:
- 0: all checks passed.
- 1: checks executed, but findings/validation failures were detected.
- 2: one or more checks failed to execute.

Requirements:
- `PSScriptAnalyzer` PowerShell module.
- Python 3.x for localization check (unless `-NoLocales`).
- `Pester` module for tests (unless `-NoPester`).
#>

[CmdletBinding(PositionalBinding = $false)]
param(
  # * Skip localization asset checks.
  [switch]$NoLocales,
  # * Skip Pester tests.
  [switch]$NoPester,
  # * Optional path to Pester tests (relative to repo root by default).
  [string]$PesterPath = "tests",
  # * Run Pester tests tagged as AV-sensitive (disabled by default).
  [switch]$IncludeAvSensitivePester,
  # * Optional file or directory paths to analyze (defaults to repo root).
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Path = @()
)

$coreScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "checker-core.ps1"
. $coreScriptPath

$exitCode = Invoke-McccCheckerCore `
  -NoLocales:$NoLocales `
  -NoPester:$NoPester `
  -PesterPath $PesterPath `
  -IncludeAvSensitivePester:$IncludeAvSensitivePester `
  -Path $Path `
  -RepoRoot $PSScriptRoot

exit $exitCode
