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

Set-StrictMode -Version Latest

$sharedConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\Shared-Config.ps1"
if (-not (Test-Path -LiteralPath $sharedConfigPath)) {
    throw ("Shared config helpers not found: {0}" -f $sharedConfigPath)
}
. $sharedConfigPath

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

# * Validate input
if (-not (Test-Path -LiteralPath $ScanPath)) {
    Write-Error ("Scan path does not exist: {0}" -f $ScanPath)
    exit 1
}

$recurse = -not $NoRecurse

if ($WriteFiles) {
    if ([string]::IsNullOrWhiteSpace($OutDir)) {
        $OutDir = Join-Path $PSScriptRoot "..\reports"
    }

    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir | Out-Null
    }
}

# * Enable ZIP reading
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-ProvidedModIdList {
    param(
        [Parameter(Mandatory = $false)]
        [object]$ProvidesValue
    )

    $provided = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $ProvidesValue) {
        return @()
    }

    if ($ProvidesValue -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($ProvidesValue)) {
            $provided.Add([string]$ProvidesValue) | Out-Null
        }
    } elseif ($ProvidesValue -is [System.Collections.IDictionary]) {
        foreach ($key in $ProvidesValue.Keys) {
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                $provided.Add([string]$key) | Out-Null
            }
        }
    } elseif ($ProvidesValue -is [pscustomobject]) {
        foreach ($prop in $ProvidesValue.PSObject.Properties) {
            if (-not [string]::IsNullOrWhiteSpace($prop.Name)) {
                $provided.Add([string]$prop.Name) | Out-Null
            }
        }
    } elseif ($ProvidesValue -is [System.Collections.IEnumerable] -and -not ($ProvidesValue -is [string])) {
        foreach ($item in $ProvidesValue) {
            if ($item -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace($item)) {
                    $provided.Add([string]$item) | Out-Null
                }
            } elseif ($item -is [pscustomobject]) {
                $itemId = ""
                if ($item.PSObject.Properties.Name -contains "id") {
                    $itemId = [string]$item.id
                }
                if (-not [string]::IsNullOrWhiteSpace($itemId)) {
                    $provided.Add($itemId) | Out-Null
                }
            }
        }
    }

    if ($provided.Count -eq 0) {
        return @()
    }

    return ,@($provided.ToArray() | Sort-Object -Unique)
}

function New-DependencyEdge {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FromModId,

        [Parameter(Mandatory = $false)]
        [string]$FromModName,

        [Parameter(Mandatory = $true)]
        [string]$DependencyId,

        [Parameter(Mandatory = $false)]
        [string]$VersionRange,

        [Parameter(Mandatory = $false)]
        [string]$Kind,

        [Parameter(Mandatory = $false)]
        [Nullable[bool]]$IsRequired,

        [Parameter(Mandatory = $false)]
        [string]$Side,

        [Parameter(Mandatory = $false)]
        [string]$Ordering,

        [Parameter(Mandatory = $false)]
        [string]$Loader,

        [Parameter(Mandatory = $false)]
        [string]$JarName,

        [Parameter(Mandatory = $false)]
        [string]$JarPath
    )

    return [PSCustomObject]@{
        FromModId    = $FromModId
        FromModName  = $FromModName
        DependencyId = $DependencyId
        VersionRange = $VersionRange
        Kind         = $Kind
        IsRequired   = $IsRequired
        Side         = $Side
        Ordering     = $Ordering
        Loader       = $Loader
        JarName      = $JarName
        JarPath      = $JarPath
    }
}

$modRecords = [System.Collections.Generic.List[object]]::new()
$dependencyEdges = [System.Collections.Generic.List[object]]::new()
$errorRecords = [System.Collections.Generic.List[object]]::new()

Write-Host ("[*] Scan path: {0}" -f $ScanPath) -ForegroundColor Cyan
Write-Host ("[*] Recursive: {0}" -f $recurse) -ForegroundColor Cyan

$jarFiles = Get-ChildItem -LiteralPath $ScanPath -Filter "*.jar" -Recurse:$recurse -File
if (-not $jarFiles -or $jarFiles.Count -eq 0) {
    Write-Warning ("No JAR files found in: {0}" -f $ScanPath)
    exit 0
}

$total = $jarFiles.Count
$index = 0

foreach ($jarFile in $jarFiles) {
    $index++
    $percent = [math]::Round(($index / $total) * 100, 0)
    Write-Progress -Activity "Scanning JAR files" -Status ("{0}/{1} {2}" -f $index, $total, $jarFile.Name) -PercentComplete $percent

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jarFile.FullName)

        $fabricText = Get-ZipEntryText -Zip $zip -EntryPath "fabric.mod.json"
        if ($fabricText) {
            $modJson = $null
            try {
                $modJson = $fabricText | ConvertFrom-Json
            } catch [System.ArgumentException] {
                throw
            } catch [System.Management.Automation.RuntimeException] {
                throw
            }

            $modId = ""
            $modName = ""
            $version = ""

            if ($modJson.PSObject.Properties.Name -contains "id") {
                $modId = [string]$modJson.id
            }
            if ($modJson.PSObject.Properties.Name -contains "name") {
                $modName = [string]$modJson.name
            }
            if ($modJson.PSObject.Properties.Name -contains "version") {
                $version = [string]$modJson.version
            }

            if ([string]::IsNullOrWhiteSpace($modId)) {
                $modId = [string]$jarFile.BaseName
            }
            if ([string]::IsNullOrWhiteSpace($modName)) {
                $modName = $modId
            }
            if ([string]::IsNullOrWhiteSpace($version)) {
                $version = "Unknown"
            }

            $providedIds = [System.Collections.Generic.List[string]]::new()
            if (-not [string]::IsNullOrWhiteSpace($modId)) {
                $providedIds.Add($modId) | Out-Null
            }
            # ! "provides" is optional in fabric.mod.json; guard before access.
            if ($modJson.PSObject.Properties.Name -contains "provides") {
                $providedFromJson = Get-ProvidedModIdList -ProvidesValue $modJson.provides
                foreach ($item in $providedFromJson) {
                    if (-not [string]::IsNullOrWhiteSpace($item)) {
                        $providedIds.Add($item) | Out-Null
                    }
                }
            }
            $providedList = @($providedIds.ToArray() | Sort-Object -Unique)

            $modRecords.Add([PSCustomObject]@{
                ModId   = $modId
                ModName = $modName
                Version = $version
                Loader  = "Fabric"
                JarName = $jarFile.Name
                JarPath = $jarFile.FullName
                ProvidedModIds = $providedList
            }) | Out-Null

            $deps = Get-FabricDependencyRecordsFromModJson -ModJson $modJson
            foreach ($dep in $deps) {
                $isRequired = $false
                if ($dep.Kind -eq "depends") {
                    $isRequired = $true
                }
                if (-not [string]::IsNullOrWhiteSpace($dep.DependencyId)) {
                    $dependencyEdges.Add((New-DependencyEdge `
                        -FromModId $modId `
                        -FromModName $modName `
                        -DependencyId $dep.DependencyId `
                        -VersionRange $dep.VersionRange `
                        -Kind $dep.Kind `
                        -IsRequired $isRequired `
                        -Loader "Fabric" `
                        -JarName $jarFile.Name `
                        -JarPath $jarFile.FullName)) | Out-Null
                }
            }

            continue
        }

        $quiltText = Get-ZipEntryText -Zip $zip -EntryPath "quilt.mod.json"
        if ($quiltText) {
            $modJson = $null
            try {
                $modJson = $quiltText | ConvertFrom-Json
            } catch [System.ArgumentException] {
                throw
            } catch [System.Management.Automation.RuntimeException] {
                throw
            }

            $loader = $null
            if ($modJson.PSObject.Properties.Name -contains "quilt_loader") {
                $loader = $modJson.quilt_loader
            }
            if ($loader) {
                $modId = ""
                $modName = ""
                $version = ""

                if ($loader.PSObject.Properties.Name -contains "id") {
                    $modId = [string]$loader.id
                }
                if ($loader.PSObject.Properties.Name -contains "version") {
                    $version = [string]$loader.version
                }
                if ($loader.PSObject.Properties.Name -contains "metadata") {
                    if ($loader.metadata -and $loader.metadata.PSObject.Properties.Name -contains "name") {
                        $modName = [string]$loader.metadata.name
                    }
                }

                if ([string]::IsNullOrWhiteSpace($modId)) {
                    $modId = [string]$jarFile.BaseName
                }
                if ([string]::IsNullOrWhiteSpace($modName)) {
                    $modName = $modId
                }
                if ([string]::IsNullOrWhiteSpace($version)) {
                    $version = "Unknown"
                }

                $providedIds = [System.Collections.Generic.List[string]]::new()
                if (-not [string]::IsNullOrWhiteSpace($modId)) {
                    $providedIds.Add($modId) | Out-Null
                }
                # ! "provides" is optional in quilt.mod.json; guard before access.
                if ($loader.PSObject.Properties.Name -contains "provides") {
                    $providedFromJson = Get-ProvidedModIdList -ProvidesValue $loader.provides
                    foreach ($item in $providedFromJson) {
                        if (-not [string]::IsNullOrWhiteSpace($item)) {
                            $providedIds.Add($item) | Out-Null
                        }
                    }
                }
                $providedList = @($providedIds.ToArray() | Sort-Object -Unique)

                $modRecords.Add([PSCustomObject]@{
                    ModId   = $modId
                    ModName = $modName
                    Version = $version
                    Loader  = "Quilt"
                    JarName = $jarFile.Name
                    JarPath = $jarFile.FullName
                    ProvidedModIds = $providedList
                }) | Out-Null

                $deps = Get-QuiltDependencyRecordsFromLoader -Loader $loader
                foreach ($dep in $deps) {
                    $isRequired = $false
                    if ($dep.Kind -eq "depends") {
                        $isRequired = $true
                    }
                    if (-not [string]::IsNullOrWhiteSpace($dep.DependencyId)) {
                        $dependencyEdges.Add((New-DependencyEdge `
                            -FromModId $modId `
                            -FromModName $modName `
                            -DependencyId $dep.DependencyId `
                            -VersionRange $dep.VersionRange `
                            -Kind $dep.Kind `
                            -IsRequired $isRequired `
                            -Loader "Quilt" `
                            -JarName $jarFile.Name `
                            -JarPath $jarFile.FullName)) | Out-Null
                    }
                }
            }

            continue
        }

        $tomlText = Get-ZipEntryText -Zip $zip -EntryPath "META-INF/mods.toml"
        $loaderName = "Forge"
        if (-not $tomlText) {
            $tomlText = Get-ZipEntryText -Zip $zip -EntryPath "META-INF/neoforge.mods.toml"
            if ($tomlText) {
                $loaderName = "NeoForge"
            }
        }

        if ($tomlText) {
            $parsed = ConvertFrom-ForgeToml -TomlText $tomlText

            $jarProvidedIds = [System.Collections.Generic.List[string]]::new()
            foreach ($mod in $parsed.Mods) {
                $modId = [string]$mod.ModId
                if (-not [string]::IsNullOrWhiteSpace($modId)) {
                    $jarProvidedIds.Add($modId) | Out-Null
                }
            }
            if ($jarProvidedIds.Count -eq 0) {
                $jarProvidedIds.Add([string]$jarFile.BaseName) | Out-Null
            }
            $jarProvidedList = @($jarProvidedIds.ToArray() | Sort-Object -Unique)

            foreach ($mod in $parsed.Mods) {
                $modId = [string]$mod.ModId
                $modName = [string]$mod.DisplayName
                $version = [string]$mod.Version

                if ([string]::IsNullOrWhiteSpace($modId)) {
                    $modId = [string]$jarFile.BaseName
                }
                if ([string]::IsNullOrWhiteSpace($modName)) {
                    $modName = $modId
                }
                if ([string]::IsNullOrWhiteSpace($version)) {
                    $version = "Unknown"
                }

                $modRecords.Add([PSCustomObject]@{
                    ModId   = $modId
                    ModName = $modName
                    Version = $version
                    Loader  = $loaderName
                    JarName = $jarFile.Name
                    JarPath = $jarFile.FullName
                    ProvidedModIds = $jarProvidedList
                }) | Out-Null
            }

            foreach ($dep in $parsed.Dependencies) {
                $fromModId = [string]$dep.OwnerModId
                if ([string]::IsNullOrWhiteSpace($fromModId)) {
                    $fromModId = [string]$jarFile.BaseName
                }

                if (-not [string]::IsNullOrWhiteSpace($dep.DependencyId)) {
                    $dependencyEdges.Add((New-DependencyEdge `
                        -FromModId $fromModId `
                        -FromModName $fromModId `
                        -DependencyId $dep.DependencyId `
                        -VersionRange $dep.VersionRange `
                        -Kind "dependency" `
                        -IsRequired $dep.Mandatory `
                        -Side $dep.Side `
                        -Ordering $dep.Ordering `
                        -Loader $loaderName `
                        -JarName $jarFile.Name `
                        -JarPath $jarFile.FullName)) | Out-Null
                }
            }
        }
    } catch [System.IO.InvalidDataException] {
        $errorRecords.Add([PSCustomObject]@{
            JarPath = $jarFile.FullName
            Error   = $_.Exception.Message
        }) | Out-Null
        Write-Warning ("Invalid archive: {0}" -f $jarFile.FullName)
    } catch [System.UnauthorizedAccessException] {
        $errorRecords.Add([PSCustomObject]@{
            JarPath = $jarFile.FullName
            Error   = $_.Exception.Message
        }) | Out-Null
        Write-Warning ("Access denied: {0}" -f $jarFile.FullName)
    } catch [System.IO.IOException] {
        $errorRecords.Add([PSCustomObject]@{
            JarPath = $jarFile.FullName
            Error   = $_.Exception.Message
        }) | Out-Null
        Write-Warning ("IO error: {0}" -f $jarFile.FullName)
    } catch {
        $errorRecords.Add([PSCustomObject]@{
            JarPath = $jarFile.FullName
            Error   = $_.Exception.Message
        }) | Out-Null
        Write-Warning ("Unhandled error: {0}" -f $jarFile.FullName)
    } finally {
        if ($zip) {
            $zip.Dispose()
        }
    }
}

Write-Progress -Activity "Scanning JAR files" -Completed

$modIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($mod in $modRecords) {
    if (-not [string]::IsNullOrWhiteSpace($mod.ModId)) {
        $modIdSet.Add([string]$mod.ModId) | Out-Null
    }
}

$dependencyUsage = $dependencyEdges |
    Group-Object -Property DependencyId |
    ForEach-Object {
        $references = $_.Group
        $requiredCount = @($references | Where-Object { $_.IsRequired -eq $true }).Count
        $refMods = $references | Select-Object -ExpandProperty FromModId -Unique
        [PSCustomObject]@{
            DependencyId     = $_.Name
            ReferenceCount   = $_.Count
            RequiredCount    = $requiredCount
            ReferencingMods  = $refMods
            IsPresentAsMod   = $modIdSet.Contains([string]$_.Name)
        }
    }

$missingDependencies = $dependencyUsage | Where-Object { $_.IsPresentAsMod -eq $false }

Write-Host ("`n[+] JARs scanned: {0}" -f $jarFiles.Count) -ForegroundColor Green
Write-Host ("[+] Mods found: {0}" -f $modRecords.Count) -ForegroundColor Green
Write-Host ("[+] Dependency edges: {0}" -f $dependencyEdges.Count) -ForegroundColor Green
Write-Host ("[+] JAR parse/read errors: {0}" -f $errorRecords.Count) -ForegroundColor Green

if ($dependencyUsage.Count -gt 0) {
    Write-Host ("`n[+] Top dependencies (by reference count):") -ForegroundColor Cyan
    $dependencyUsage |
        Sort-Object -Property ReferenceCount -Descending |
        Select-Object -First $TopDependencies |
        ForEach-Object {
            $presence = "missing"
            if ($_.IsPresentAsMod) {
                $presence = "present"
            }
            Write-Host ("- {0} | refs: {1} | required: {2} | {3}" -f $_.DependencyId, $_.ReferenceCount, $_.RequiredCount, $presence)
        }
}

if ($missingDependencies.Count -gt 0) {
    $requiredMissingDependencies = @($missingDependencies | Where-Object { $_.RequiredCount -gt 0 })
    Write-Host ("`n[!] Dependency IDs without provider mods in scan path: {0}" -f $missingDependencies.Count) -ForegroundColor Yellow
    Write-Host ("[!] Of them required by at least one mod: {0}" -f $requiredMissingDependencies.Count) -ForegroundColor Yellow
}

$dependencyMap = [PSCustomObject]@{
    Scan = [PSCustomObject]@{
        Path          = $ScanPath
        Recursive     = $recurse
        JarCount      = $jarFiles.Count
        ModCount      = $modRecords.Count
        DependencyCount = $dependencyEdges.Count
        GeneratedAt   = (Get-Date).ToString("s")
    }
    Mods               = $modRecords
    Dependencies       = $dependencyEdges
    Usage              = $dependencyUsage
    MissingDependencies = $missingDependencies
    Errors             = $errorRecords
}

if ($WriteFiles) {
    $jsonPath = Join-Path $OutDir "jar-dependency-map.json"
    $csvPath = Join-Path $OutDir "jar-dependency-edges.csv"
    $summaryPath = Join-Path $OutDir "jar-dependency-summary.json"

    $dependencyMap | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    $dependencyEdges | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    $dependencyUsage | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

    Write-Host ("`n[+] Reports written to: {0}" -f $OutDir) -ForegroundColor Green
    Write-Host ("- {0}" -f $jsonPath)
    Write-Host ("- {0}" -f $csvPath)
    Write-Host ("- {0}" -f $summaryPath)
}
