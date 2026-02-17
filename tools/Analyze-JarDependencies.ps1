# * Script to search for dependencies inside Minecraft mod JAR files (Fabric/Forge)
# * Uses direct ZIP archive reading for high performance.

param(
  [Parameter(Mandatory = $true, HelpMessage = "Part of the dependency name or ID to search for (e.g., 'owo')")]
  [string]$SearchTerm,

  [Parameter(Mandatory = $false)]
  [string]$ScanPath = ".",

  [Parameter(Mandatory = $false)]
  [switch]$Recurse,

  [Parameter(Mandatory = $false)]
  [switch]$NoRecurse
)

$sharedBootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\Shared-Bootstrap.ps1"
if (-not (Test-Path -LiteralPath $sharedBootstrapPath)) {
  throw ("Shared bootstrap helpers not found: {0}" -f $sharedBootstrapPath)
}
. $sharedBootstrapPath
. Initialize-McccRuntimeBootstrap `
  -StartDir $PSScriptRoot `
  -InitializeLocalization `
  -EnableConsoleLocalization `
  -LocalizationNotFoundMessage "Shared localization helpers not found: {0}" | Out-Null

$sharedJarMetadataPath = Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\Shared-JarMetadata.ps1"
if (-not (Test-Path -LiteralPath $sharedJarMetadataPath)) {
  throw ("Shared jar metadata helpers not found: {0}" -f $sharedJarMetadataPath)
}
. $sharedJarMetadataPath

$sharedToolPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-Analyze-JarDependencies.ps1"
if (-not (Test-Path -LiteralPath $sharedToolPath)) {
  throw ("Shared dependency-search tool helpers not found: {0}" -f $sharedToolPath)
}
. $sharedToolPath

$scanRecursively = Resolve-McccJarDependencySearchRecurseMode `
  -BoundParameters $PSBoundParameters `
  -Recurse ([bool]$Recurse) `
  -NoRecurse ([bool]$NoRecurse)

Write-Host ("[*] Scanning: {0}" -f $ScanPath) -ForegroundColor Cyan
Write-Host ("[*] Searching dependency: '{0}'" -f $SearchTerm) -ForegroundColor Cyan

$scanData = Get-McccJarDependencySearchScanData `
  -SearchTerm $SearchTerm `
  -ScanPath $ScanPath `
  -Recurse $scanRecursively

$results = ConvertTo-McccJarDependencySearchResults -RawMatches @($scanData.RawMatches)
Write-McccJarDependencySearchConsoleReport -Results @($results)
