function Resolve-McccJarDependencySearchRecurseMode {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$BoundParameters,
    [Parameter(Mandatory = $true)]
    [bool]$Recurse,
    [Parameter(Mandatory = $true)]
    [bool]$NoRecurse
  )

  $scanRecursively = $true
  if ($BoundParameters.ContainsKey("Recurse")) {
    $scanRecursively = [bool]$Recurse
  }
  if ($NoRecurse) {
    $scanRecursively = $false
  }
  return $scanRecursively
}

function Get-McccJarDependencySearchScanData {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SearchTerm,
    [Parameter(Mandatory = $true)]
    [string]$ScanPath,
    [Parameter(Mandatory = $true)]
    [bool]$Recurse
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem

  $searchPattern = "*{0}*" -f $SearchTerm
  $rawMatches = New-Object System.Collections.Generic.List[object]
  $jarFiles = @(Get-ChildItem -Path $ScanPath -Filter "*.jar" -Recurse:$Recurse)

  foreach ($jarFile in $jarFiles) {
    $zip = $null
    try {
      $zip = [System.IO.Compression.ZipFile]::OpenRead($jarFile.FullName)

      $fabricText = Get-McccJarEntryText -Zip $zip -EntryPath "fabric.mod.json"
      if ($fabricText) {
        $metadata = $null
        try {
          $metadata = Get-McccJarMetadataFromZipArchive -Zip $zip -JarPath $jarFile.FullName -ThrowOnParseError $false
        } catch {
          $metadata = $null
        }

        $record = $null
        if ($null -ne $metadata -and [string]$metadata.Loader -eq "Fabric") {
          $records = @($metadata.Records)
          if ($records.Count -gt 0) {
            $record = $records[0]
          }
        }

        if ($null -ne $record) {
          $foundDeps = New-Object System.Collections.Generic.List[string]
          foreach ($dep in @($record.Dependencies)) {
            if ($null -eq $dep) { continue }
            $depId = [string]$dep.ModId
            if ([string]::IsNullOrWhiteSpace($depId)) { continue }
            if ($depId -like $searchPattern) {
              $foundDeps.Add(("{0}: {1} ({2})" -f $depId, [string]$dep.VersionRange, [string]$dep.Kind)) | Out-Null
            }
          }

          if ($foundDeps.Count -gt 0) {
            $rawMatches.Add([pscustomobject]@{
                ModName           = [string]$record.DisplayName
                JarName           = $jarFile.Name
                Version           = [string]$record.Version
                FoundDependencies = @($foundDeps.ToArray())
                Type              = "Fabric"
                Path              = $jarFile.FullName
              }) | Out-Null
          }
        }
      }

      if (-not $fabricText) {
        $tomlText = Get-McccJarEntryText -Zip $zip -EntryPath "META-INF/mods.toml"
        if ($tomlText -and $tomlText -like $searchPattern) {
          $rawMatches.Add([pscustomobject]@{
              ModName           = "Forge Mod (ID unknown)"
              JarName           = $jarFile.Name
              Version           = "Unknown"
              FoundDependencies = @("Found '{0}' in mods.toml" -f $SearchTerm)
              Type              = "Forge"
              Path              = $jarFile.FullName
            }) | Out-Null
        }
      }

      $zip.Dispose()
    } catch {
      if ($zip) { $zip.Dispose() }
    }
  }

  return [pscustomobject]@{
    JarFiles    = @($jarFiles)
    RawMatches  = @($rawMatches.ToArray())
  }
}

function ConvertTo-McccJarDependencySearchResults {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$RawMatches = @()
  )

  $results = New-Object System.Collections.Generic.List[object]
  foreach ($match in @($RawMatches)) {
    if ($null -eq $match) { continue }

    $results.Add([pscustomobject]@{
        ModName      = [string]$match.ModName
        JarName      = [string]$match.JarName
        Version      = [string]$match.Version
        Dependencies = (@($match.FoundDependencies) -join "; ")
        Type         = [string]$match.Type
        Path         = [string]$match.Path
      }) | Out-Null
  }

  return @($results.ToArray())
}

function Write-McccJarDependencySearchConsoleReport {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$Results = @()
  )

  if (@($Results).Count -gt 0) {
    Write-Host ("`n[+] Matches found: {0}" -f @($Results).Count) -ForegroundColor Green
    foreach ($result in @($Results)) {
      Write-Host ("`nMod: {0} ({1})" -f $result.ModName, $result.Type) -ForegroundColor Yellow
      Write-Host ("JAR:     {0}" -f $result.JarName)
      Write-Host ("Version:  {0}" -f $result.Version)
      Write-Host ("Deps:     {0}" -f $result.Dependencies)
      Write-Host ("Path:     {0}" -f $result.Path)
    }
  } else {
    Write-Host "`n[-] No matches found." -ForegroundColor Red
  }
}
