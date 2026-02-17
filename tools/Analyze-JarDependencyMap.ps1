<#
.SYNOPSIS
Builds a full dependency map for Minecraft mod JARs.

.DESCRIPTION
Scans all JAR files under a directory, parses Fabric/Quilt JSON and Forge/NeoForge
TOML metadata, and produces a dependency map with usage statistics.

.PARAMETER ScanPath
Root folder that contains JAR files to scan.

.PARAMETER NoRecurse
Disable recursive scanning.

.PARAMETER WriteFiles
Write JSON/CSV reports to OutDir.

.PARAMETER OutDir
Output directory for reports. Created if it does not exist.

.PARAMETER TopDependencies
Number of dependencies to show in the console summary.

.EXAMPLE
.\tools\Analyze-JarDependencyMap.ps1

.EXAMPLE
.\tools\Analyze-JarDependencyMap.ps1 -ScanPath "D:\Mods" -WriteFiles:$false
#>
param(
  [Parameter(Mandatory = $false, HelpMessage = "Root folder with Minecraft mod JAR files (defaults to Paths.GameModsDir from config.ini).")]
  [string]$ScanPath = "",

  [Parameter(Mandatory = $false, HelpMessage = "Disable recursive scan.")]
  [switch]$NoRecurse,

  [Parameter(Mandatory = $false, HelpMessage = "Write JSON/CSV reports to OutDir.")]
  [bool]$WriteFiles = $true,

  [Parameter(Mandatory = $false, HelpMessage = "Output directory for reports.")]
  [string]$OutDir = "",

  [Parameter(Mandatory = $false, HelpMessage = "Number of dependencies to show in summary.")]
  [int]$TopDependencies = 30
)

$sharedBootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\Shared-Bootstrap.ps1"
if (-not (Test-Path -LiteralPath $sharedBootstrapPath)) {
  throw ("Shared bootstrap helpers not found: {0}" -f $sharedBootstrapPath)
}
. $sharedBootstrapPath
$runtimeBootstrap = . Initialize-McccRuntimeBootstrap `
  -StartDir $PSScriptRoot `
  -LoadConfig `
  -InitializeLocalization `
  -EnableConsoleLocalization `
  -ConfigNotFoundMessage "Shared config helpers not found: {0}" `
  -LocalizationNotFoundMessage "Shared localization helpers not found: {0}"

Set-StrictMode -Version Latest
$projectRootPath = [string]$runtimeBootstrap.ProjectRoot

$runtimeBound = @{}
if (-not [string]::IsNullOrWhiteSpace($ScanPath)) {
  $runtimeBound["GameModsDir"] = $true
}
$runtimeConfig = Initialize-McccRuntimeConfig `
  -StartDir $PSScriptRoot `
  -BoundParameters $runtimeBound `
  -GameModsDir $ScanPath `
  -AlwaysDefaultGameModsDir $true `
  -DefaultStorageToGame $false `
  -TreatEmptyAsUnboundKeys @("GameModsDir")
$ScanPath = $runtimeConfig.Paths.GameModsDir

$sharedJarDepPath = Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\Shared-Isolation-JarDependencies.ps1"
if (-not (Test-Path -LiteralPath $sharedJarDepPath)) {
  throw ("Shared jar dependency helpers not found: {0}" -f $sharedJarDepPath)
}
. $sharedJarDepPath

$sharedToolPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Analyze-JarDependencyMap.ps1"
if (-not (Test-Path -LiteralPath $sharedToolPath)) {
  throw ("Shared dependency-map tool helpers not found: {0}" -f $sharedToolPath)
}
. $sharedToolPath

if (-not (Test-Path -LiteralPath $ScanPath)) {
  Write-Error ("Scan path does not exist: {0}" -f $ScanPath)
  exit 1
}

$recurse = -not $NoRecurse
if ($WriteFiles) {
  if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path -Path $projectRootPath -ChildPath "reports"
  }

  if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
  }
}

Write-Host ("[*] Scan path: {0}" -f $ScanPath) -ForegroundColor Cyan
Write-Host ("[*] Recursive: {0}" -f $recurse) -ForegroundColor Cyan

$scanData = Get-McccJarDependencyMapScanData -ScanPath $ScanPath -Recurse $recurse
$jarFiles = @($scanData.JarFiles)
$modRecords = @($scanData.ModRecords)
$dependencyEdges = @($scanData.DependencyEdges)
$errorRecords = @($scanData.ErrorRecords)
$warningRecords = @($scanData.WarningRecords)
$diagnosticRecords = @($scanData.Diagnostics)

if ($jarFiles.Count -eq 0) {
  Write-Warning ("No JAR files found in: {0}" -f $ScanPath)
  exit 0
}

$usageData = Get-McccJarDependencyMapUsageData -ModRecords $modRecords -DependencyEdges $dependencyEdges
$dependencyUsage = @($usageData.Usage)
$missingDependencies = @($usageData.MissingDependencies)

Write-McccJarDependencyMapConsoleReport `
  -JarFiles $jarFiles `
  -ModRecords $modRecords `
  -DependencyEdges $dependencyEdges `
  -ErrorRecords $errorRecords `
  -DependencyUsage $dependencyUsage `
  -MissingDependencies $missingDependencies `
  -TopDependencies $TopDependencies

$dependencyMap = New-McccJarDependencyMapReportData `
  -ScanPath $ScanPath `
  -Recurse $recurse `
  -JarFiles $jarFiles `
  -ModRecords $modRecords `
  -DependencyEdges $dependencyEdges `
  -DependencyUsage $dependencyUsage `
  -MissingDependencies $missingDependencies `
  -WarningRecords $warningRecords `
  -ErrorRecords $errorRecords `
  -Diagnostics $diagnosticRecords

if ($WriteFiles) {
  $writtenReports = Export-McccJarDependencyMapReports `
    -OutDir $OutDir `
    -DependencyMap $dependencyMap `
    -DependencyEdges $dependencyEdges `
    -DependencyUsage $dependencyUsage

  Write-Host ("`n[+] Reports written to: {0}" -f $OutDir) -ForegroundColor Green
  Write-Host ("- {0}" -f [string]$writtenReports.JsonPath)
  Write-Host ("- {0}" -f [string]$writtenReports.CsvPath)
  Write-Host ("- {0}" -f [string]$writtenReports.SummaryPath)
}
