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

$sharedLocalizationPath = Join-Path -Path $PSScriptRoot -ChildPath "..\scripts\Shared-Localization.ps1"
if (-not (Test-Path -LiteralPath $sharedLocalizationPath)) {
    throw ("Shared localization helpers not found: {0}" -f $sharedLocalizationPath)
}
. $sharedLocalizationPath
Initialize-McccLocalization -StartDir $PSScriptRoot | Out-Null
Enable-McccConsoleLocalization

# * Include library for archive handling
Add-Type -AssemblyName System.IO.Compression.FileSystem

$results = @()
$searchPattern = "*{0}*" -f $SearchTerm
$scanRecursively = $true
if ($PSBoundParameters.ContainsKey("Recurse")) {
    $scanRecursively = [bool]$Recurse
}
if ($NoRecurse) {
    $scanRecursively = $false
}

Write-Host ("[*] Scanning: {0}" -f $ScanPath) -ForegroundColor Cyan
Write-Host ("[*] Searching dependency: '{0}'" -f $SearchTerm) -ForegroundColor Cyan

$jarFiles = Get-ChildItem -Path $ScanPath -Filter "*.jar" -Recurse:$scanRecursively

foreach ($jarFile in $jarFiles) {
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jarFile.FullName)

        # ? 1. Check Fabric (fabric.mod.json)
        $fabricEntry = $zip.Entries | Where-Object { $_.FullName -eq "fabric.mod.json" }
        if ($fabricEntry) {
            $stream = $fabricEntry.Open()
            $reader = New-Object System.IO.StreamReader($stream)
            $content = $reader.ReadToEnd()
            $reader.Close()
            $stream.Close()

            $modJson = $content | ConvertFrom-Json
            $foundDeps = @()

            # ! Check all possible dependency blocks in Fabric
            $depBlocks = @("depends", "suggests", "recommends", "breaks", "conflicts")
            foreach ($block in $depBlocks) {
                if ($modJson.PSObject.Properties.Name -contains $block) {
                    foreach ($prop in $modJson.$block.PSObject.Properties) {
                        if ($prop.Name -like $searchPattern) {
                            $foundDeps += "{0}: {1} ({2})" -f $prop.Name, $prop.Value, $block
                        }
                    }
                }
            }

            if ($foundDeps.Count -gt 0) {
                $results += [PSCustomObject]@{
                    ModName      = $modJson.name
                    JarName      = $jarFile.Name
                    Version      = $modJson.version
                    Dependencies = $foundDeps -join "; "
                    Type         = "Fabric"
                    Path         = $jarFile.FullName
                }
            }
        }

        # ? 2. Check Forge (META-INF/mods.toml)
        if (-not $fabricEntry) {
            $tomlEntry = $zip.Entries | Where-Object { $_.FullName -eq "META-INF/mods.toml" }
            if ($tomlEntry) {
                $stream = $tomlEntry.Open()
                $reader = New-Object System.IO.StreamReader($stream)
                $content = $reader.ReadToEnd()
                $reader.Close()
                $stream.Close()

                if ($content -like $searchPattern) {
                    $results += [PSCustomObject]@{
                        ModName      = "Forge Mod (ID unknown)"
                        JarName      = $jarFile.Name
                        Version      = "Unknown"
                        Dependencies = "Found '{0}' in mods.toml" -f $SearchTerm
                        Type         = "Forge"
                        Path         = $jarFile.FullName
                    }
                }
            }
        }

        $zip.Dispose()

    } catch {
        if ($zip) { $zip.Dispose() }
        # ! Ignore access errors or corrupted archives if needed
        # Write-Warning ("Error while processing {0}: {1}" -f $jarFile.Name, $_.Exception.Message)
    }
}

# * Output results
if ($results.Count -gt 0) {
    Write-Host ("`n[+] Matches found: {0}" -f $results.Count) -ForegroundColor Green
    foreach ($result in $results) {
        Write-Host ("`nMod: {0} ({1})" -f $result.ModName, $result.Type) -ForegroundColor Yellow
        Write-Host ("JAR:     {0}" -f $result.JarName)
        Write-Host ("Version:  {0}" -f $result.Version)
        Write-Host ("Deps:     {0}" -f $result.Dependencies)
        Write-Host ("Path:     {0}" -f $result.Path)
    }
} else {
    Write-Host "`n[-] No matches found." -ForegroundColor Red
}
