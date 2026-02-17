$sharedJarToolsPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-JarTools.ps1"
if (-not (Test-Path -LiteralPath $sharedJarToolsPath)) {
  throw ("Shared jar helpers not found: {0}" -f $sharedJarToolsPath)
}
. $sharedJarToolsPath

$sharedJarMetadataPath = Join-Path -Path $PSScriptRoot -ChildPath "Shared-JarMetadata.ps1"
if (-not (Test-Path -LiteralPath $sharedJarMetadataPath)) {
  throw ("Shared jar metadata helpers not found: {0}" -f $sharedJarMetadataPath)
}
. $sharedJarMetadataPath

function Test-AnyIdOverlap {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$IdsA = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$IdsB = @()
  )

  if (-not $IdsA -or $IdsA.Count -eq 0) { return $false }
  if (-not $IdsB -or $IdsB.Count -eq 0) { return $false }
  $set = @{}
  foreach ($id in $IdsA) { $set[$id.ToLowerInvariant()] = $true }
  foreach ($id in $IdsB) {
    if ($set.ContainsKey($id.ToLowerInvariant())) { return $true }
  }
  return $false
}

function ConvertTo-VersionRangeString {
  param(
    [Parameter(Mandatory = $false)]
    [object]$Value
  )

  return ConvertTo-McccVersionRangeString -Value $Value
}

function Test-JarNameMatchesAnyId {
  <#
  .SYNOPSIS
  Best-effort match: checks whether a jar file name likely corresponds to a dependency id.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarName,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$Ids = @(),
    [Parameter(Mandatory = $false)]
    [bool]$AllowTokenMatch = $true
  )

  if ([string]::IsNullOrWhiteSpace($JarName)) { return $false }
  if (-not $Ids -or $Ids.Count -eq 0) { return $false }

  $name = $JarName.ToLowerInvariant()
  foreach ($id in $Ids) {
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $idLower = $id.ToLowerInvariant()
    if ($name -like ("*{0}*" -f $idLower)) { return $true }

    if ($AllowTokenMatch) {
      # * Token match for cases like: missing dep "libjf-base" vs jar "libjf-3.19.3+backport.jar".
      # ! Avoid overly generic token matches that can accidentally match most jars (e.g. "fabric").
      $stopTokens = @{
        "api"       = $true
        "client"    = $true
        "common"    = $true
        "core"      = $true
        "fabric"    = $true
        "forge"     = $true
        "loader"    = $true
        "mixin"     = $true
        "mc"        = $true
        "minecraft" = $true
        "mod"       = $true
        "modloader" = $true
        "mods"      = $true
        "neoforge"  = $true
        "quilt"     = $true
        "server"    = $true
      }
      $tokens = $idLower -split "[-_\\.]"
      foreach ($t in $tokens) {
        if ($t.Length -lt 3) { continue }
        if ($stopTokens.ContainsKey($t)) { continue }
        if ($name -like ("*{0}*" -f $t)) { return $true }
      }
    }
  }
  return $false
}

function Resolve-JarsByName {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Dirs,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$JarNames
  )

  if (-not $Dirs -or $Dirs.Count -eq 0) { return @() }
  if (-not $JarNames -or $JarNames.Count -eq 0) { return @() }

  $nameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($name in $JarNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $null = $nameSet.Add([string]$name)
  }
  if ($nameSet.Count -eq 0) { return @() }

  $resolved = New-Object System.Collections.Generic.List[object]
  foreach ($dir in $Dirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $jars = @(Get-McccJarFiles -RootPaths @($dir) -SortBy "None" -EnumerationErrorAction "SilentlyContinue")
    foreach ($jar in $jars) {
      if ($nameSet.Contains($jar.Name)) {
        $resolved.Add($jar) | Out-Null
      }
    }
  }

  if ($resolved.Count -eq 0) { return @() }
  return ,@($resolved.ToArray() | Sort-Object -Property FullName -Unique)
}

function Get-ModJarsByIdsFromDependencyMap {
  <#
  .SYNOPSIS
  Resolves mod IDs to jar files using the prebuilt dependency map (if available).
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Dirs,
    [Parameter(Mandatory = $true)]
    [string[]]$ModIds
  )

  if (-not $ModIds -or $ModIds.Count -eq 0) { return @() }
  if (-not $Dirs -or $Dirs.Count -eq 0) { return @() }
  if (-not $script:dependencyMapByModId -or $script:dependencyMapByModId.Count -eq 0) { return @() }

  $jarNames = New-Object System.Collections.Generic.List[string]
  foreach ($id in $ModIds) {
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $key = $id.ToLowerInvariant()
    if (-not $script:dependencyMapByModId.ContainsKey($key)) { continue }
    foreach ($name in $script:dependencyMapByModId[$key]) {
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      $jarNames.Add([string]$name) | Out-Null
    }
  }

  if ($jarNames.Count -eq 0) { return @() }
  return Resolve-JarsByName -Dirs $Dirs -JarNames $jarNames
}

function Find-ModJarById {
  <#
  .SYNOPSIS
  Finds jar files that provide the given mod IDs in specified directories.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Dirs,
    [Parameter(Mandatory = $true)]
    [string[]]$ModIds
  )

  if (-not $ModIds -or $ModIds.Count -eq 0) { return @() }
  if (-not $Dirs -or $Dirs.Count -eq 0) { return @() }

  $fromDependencyMap = Get-ModJarsByIdsFromDependencyMap -Dirs $Dirs -ModIds $ModIds
  if ($fromDependencyMap -and $fromDependencyMap.Count -gt 0) {
    return ,@($fromDependencyMap | Sort-Object -Property FullName -Unique)
  }

  $idSet = @{}
  foreach ($id in $ModIds) {
    $idSet[$id.ToLowerInvariant()] = $true
  }

  $foundJars = New-Object System.Collections.Generic.List[object]
  foreach ($dir in $Dirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $jars = @(Get-McccJarFiles -RootPaths @($dir) -SortBy "None" -EnumerationErrorAction "SilentlyContinue")
    foreach ($jar in $jars) {
      $jarIds = Get-FabricModIdsFromJar -JarPath $jar.FullName
      if (-not $jarIds) { continue }
      foreach ($jarId in $jarIds) {
        if ($idSet.ContainsKey($jarId.ToLowerInvariant())) {
          $foundJars.Add($jar)
          break
        }
      }
    }
  }

  if ($foundJars.Count -eq 0) { return @() }
  return ,@($foundJars.ToArray() | Sort-Object -Property FullName -Unique)
}

function Find-ModJarByIdBestEffort {
  <#
  .SYNOPSIS
  Finds jar files for mod IDs using metadata first, then filename heuristics.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Dirs,
    [Parameter(Mandatory = $true)]
    [string[]]$ModIds,
    [Parameter(Mandatory = $false)]
    [bool]$AllowTokenFallback = $true
  )

  if (-not $ModIds -or $ModIds.Count -eq 0) { return @() }
  if (-not $Dirs -or $Dirs.Count -eq 0) { return @() }

  $byMetadata = Find-ModJarById -Dirs $Dirs -ModIds $ModIds
  if ($byMetadata -and $byMetadata.Count -gt 0) {
    return ,@($byMetadata | Sort-Object -Property FullName -Unique)
  }

  # * Fallback: match jar filenames against the ids/tokens (for edge cases where fabric.mod.json is missing/unreadable).
  $matched = New-Object System.Collections.Generic.List[object]
  foreach ($dir in $Dirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $jars = @(Get-McccJarFiles -RootPaths @($dir) -SortBy "None" -EnumerationErrorAction "SilentlyContinue")
    foreach ($jar in $jars) {
      if (Test-JarNameMatchesAnyId -JarName $jar.Name -Ids $ModIds -AllowTokenMatch $AllowTokenFallback) {
        $matched.Add($jar)
      }
    }
  }
  if ($matched.Count -eq 0) { return @() }
  return ,@($matched.ToArray() | Sort-Object -Property FullName -Unique)
}

# * Reads a text entry from a jar (zip) without extracting.
function Get-JarZipEntryText {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.Compression.ZipArchive]$Zip,
    [Parameter(Mandatory = $true)]
    [string]$EntryPath
  )

  return Get-McccJarEntryText -Zip $Zip -EntryPath $EntryPath
}

function Get-ZipEntryText {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.Compression.ZipArchive]$Zip,
    [Parameter(Mandatory = $true)]
    [string]$EntryPath
  )

  return Get-McccJarEntryText -Zip $Zip -EntryPath $EntryPath
}

function Get-FabricDependencyRecordsFromModJson {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$ModJson
  )

  $ownerModId = ""
  if ($ModJson.PSObject.Properties.Name -contains "id") {
    $ownerModId = [string]$ModJson.id
  }

  $canonicalDeps = @(Get-McccFabricDependencyList -ModJson $ModJson -OwnerModId $ownerModId)
  $deps = New-Object System.Collections.Generic.List[object]
  foreach ($dep in $canonicalDeps) {
    if ($null -eq $dep) { continue }
    $depId = [string]$dep.ModId
    if ([string]::IsNullOrWhiteSpace($depId)) { continue }
    $deps.Add([pscustomobject]@{
        DependencyId = $depId
        VersionRange = [string]$dep.VersionRange
        Kind = [string]$dep.Kind
      }) | Out-Null
  }
  return ,@($deps.ToArray())
}

function Get-QuiltDependencyRecordsFromLoader {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Loader
  )

  $ownerModId = ""
  if ($Loader.PSObject.Properties.Name -contains "id") {
    $ownerModId = [string]$Loader.id
  }

  $canonicalDeps = @(Get-McccQuiltDependencyList -Loader $Loader -OwnerModId $ownerModId)
  $deps = New-Object System.Collections.Generic.List[object]
  foreach ($dep in $canonicalDeps) {
    if ($null -eq $dep) { continue }
    $depId = [string]$dep.ModId
    if ([string]::IsNullOrWhiteSpace($depId)) { continue }
    $deps.Add([pscustomobject]@{
        DependencyId = $depId
        VersionRange = [string]$dep.VersionRange
        Kind = [string]$dep.Kind
      }) | Out-Null
  }
  return ,@($deps.ToArray())
}

function ConvertFrom-ForgeToml {
  <#
  .SYNOPSIS
  Parses mods.toml / neoforge.mods.toml to extract mod ids and dependency blocks.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$TomlText
  )

  $parsed = ConvertFrom-McccForgeToml -TomlText $TomlText
  $legacyMods = New-Object System.Collections.Generic.List[object]
  foreach ($mod in @($parsed.Mods)) {
    if ($null -eq $mod) { continue }
    $legacyMods.Add([pscustomobject]@{
        ModId = [string]$mod.ModId
        DisplayName = [string]$mod.DisplayName
        Version = [string]$mod.Version
      }) | Out-Null
  }

  $legacyDeps = New-Object System.Collections.Generic.List[object]
  foreach ($dep in @($parsed.Dependencies)) {
    if ($null -eq $dep) { continue }
    $legacyDeps.Add([pscustomobject]@{
        OwnerModId = [string]$dep.OwnerModId
        DependencyId = [string]$dep.ModId
        VersionRange = [string]$dep.VersionRange
        Mandatory = $dep.IsRequired
        Side = [string]$dep.Side
        Ordering = [string]$dep.Ordering
      }) | Out-Null
  }

  return [pscustomobject]@{
    Mods = @($legacyMods.ToArray())
    Dependencies = @($legacyDeps.ToArray())
  }
}

function Get-JarDependencyInfo {
  <#
  .SYNOPSIS
  Extracts mod ids provided by a jar and dependency edges declared in its metadata.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarPath
  )

  if (-not (Test-Path -LiteralPath $JarPath)) {
    return $null
  }

  $metadata = $null
  try {
    $metadata = Get-McccJarMetadata -JarPath $JarPath -ThrowOnParseError $false
  } catch {
    return $null
  }
  if ($null -eq $metadata) { return $null }

  $provided = New-Object System.Collections.Generic.List[string]
  if ($metadata.PSObject.Properties.Name -contains "JarProvidedIds") {
    foreach ($id in @($metadata.JarProvidedIds)) {
      $value = [string]$id
      if ([string]::IsNullOrWhiteSpace($value)) { continue }
      $provided.Add($value) | Out-Null
    }
  }

  $fallbackFromId = [System.IO.Path]::GetFileNameWithoutExtension($JarPath)
  $defaultFromId = $fallbackFromId
  $records = @($metadata.Records)
  if ($records.Count -gt 0) {
    $recordModId = [string]$records[0].ModId
    if (-not [string]::IsNullOrWhiteSpace($recordModId)) {
      $defaultFromId = $recordModId
    }
  }

  $edges = New-Object System.Collections.Generic.List[object]
  foreach ($dep in @($metadata.DependencyRecords)) {
    if ($null -eq $dep) { continue }
    $depId = [string]$dep.ModId
    if ([string]::IsNullOrWhiteSpace($depId)) { continue }

    $fromId = [string]$dep.OwnerModId
    if ([string]::IsNullOrWhiteSpace($fromId)) {
      $fromId = $defaultFromId
    }
    if ([string]::IsNullOrWhiteSpace($fromId)) {
      $fromId = $fallbackFromId
    }

    $isRequired = $false
    if ($dep.PSObject.Properties.Name -contains "IsRequired" -and $null -ne $dep.IsRequired) {
      $isRequired = [bool]$dep.IsRequired
    } elseif ([string]$dep.Kind -eq "depends") {
      $isRequired = $true
    }

    $edges.Add([pscustomobject]@{
        FromModId = $fromId
        DependencyId = $depId
        IsRequired = $isRequired
      }) | Out-Null
  }

  return [pscustomobject]@{
    Loader = [string]$metadata.Loader
    ProvidedModIds = @($provided.ToArray() | Sort-Object -Unique)
    DependencyEdges = @($edges.ToArray())
  }
}

function Get-DependentModCountsByJarName {
  <#
  .SYNOPSIS
  Builds a map jarName->dependentCount where dependentCount is how many other mods reference this mod id.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModsDir,
    [Parameter(Mandatory = $false)]
    [ValidateSet("RequiredOnly", "All")]
    [string]$CountMode = "RequiredOnly"
  )

  $jarFiles = @(Get-McccJarFiles -RootPaths @($ModsDir) -SortBy "None" -EnumerationErrorAction "SilentlyContinue")
  if (-not $jarFiles -or $jarFiles.Count -eq 0) {
    return @{}
  }

  $incomingById = @{}
  $providedIdsByJar = @{}

  foreach ($jar in $jarFiles) {
    $jarKey = $jar.Name.ToLowerInvariant()
    $info = Get-JarDependencyInfo -JarPath $jar.FullName
    if ($null -eq $info) {
      $providedIdsByJar[$jarKey] = @()
      continue
    }

    $provided = @($info.ProvidedModIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $providedLower = @($provided | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    $providedIdsByJar[$jarKey] = $providedLower

    $edges = @($info.DependencyEdges)
    foreach ($edge in $edges) {
      if ($null -eq $edge) { continue }
      $depId = [string]$edge.DependencyId
      $fromId = [string]$edge.FromModId
      if ([string]::IsNullOrWhiteSpace($depId) -or [string]::IsNullOrWhiteSpace($fromId)) { continue }

      $isRequired = [bool]$edge.IsRequired
      if ($CountMode -eq "RequiredOnly" -and (-not $isRequired)) { continue }

      $depKey = $depId.ToLowerInvariant()
      $fromKey = $fromId.ToLowerInvariant()
      if (-not $incomingById.ContainsKey($depKey)) {
        $incomingById[$depKey] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
      }
      $null = $incomingById[$depKey].Add($fromKey)
    }
  }

  $result = @{}
  foreach ($jarKey in $providedIdsByJar.Keys) {
    $ids = @($providedIdsByJar[$jarKey])
    if (-not $ids -or $ids.Count -eq 0) {
      $result[$jarKey] = [pscustomobject]@{
        DependentCount = -1
        Known = $false
        ProvidedModIds = @()
      }
      continue
    }

    $max = 0
    foreach ($id in $ids) {
      if ($incomingById.ContainsKey($id)) {
        $count = $incomingById[$id].Count
        if ($count -gt $max) { $max = $count }
      }
    }
    $result[$jarKey] = [pscustomobject]@{
      DependentCount = [int]$max
      Known = $true
      ProvidedModIds = @($ids)
    }
  }

  return $result
}

function Read-DependencyMapJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$JsonPath
  )

  if ([string]::IsNullOrWhiteSpace($JsonPath)) { return $null }
  if (-not (Test-Path -LiteralPath $JsonPath)) { return $null }

  try {
    $raw = Get-Content -LiteralPath $JsonPath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    Write-Host ("Warning: failed to read dependency map JSON: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    return $null
  }
}

function Initialize-DependencyMapCache {
  param(
    [Parameter(Mandatory = $false)]
    [pscustomobject]$DependencyMap
  )

  $script:dependencyMapByModId = @{}
  $script:dependencyMapProvidedIdsByJar = @{}
  $script:dependencyMapScanPath = ""

  if ($null -eq $DependencyMap) { return }

  if ($DependencyMap.PSObject.Properties.Name -contains "Scan") {
    $scanPath = [string]$DependencyMap.Scan.Path
    if (-not [string]::IsNullOrWhiteSpace($scanPath)) {
      $script:dependencyMapScanPath = $scanPath
    }
  }

  $mods = @($DependencyMap.Mods)
  foreach ($mod in $mods) {
    if ($null -eq $mod) { continue }
    $jarName = [string]$mod.JarName
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }

    $jarKey = $jarName.ToLowerInvariant()
    if (-not $script:dependencyMapProvidedIdsByJar.ContainsKey($jarKey)) {
      $script:dependencyMapProvidedIdsByJar[$jarKey] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    $providedIds = New-Object System.Collections.Generic.List[string]
    if ($mod.PSObject.Properties.Name -contains "ModId") {
      $modId = [string]$mod.ModId
      if (-not [string]::IsNullOrWhiteSpace($modId)) {
        $providedIds.Add($modId) | Out-Null
      }
    }
    if ($mod.PSObject.Properties.Name -contains "ProvidedModIds") {
      foreach ($item in $mod.ProvidedModIds) {
        $value = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($value)) {
          $providedIds.Add($value) | Out-Null
        }
      }
    }

    $uniqueProvided = @($providedIds.ToArray() | Sort-Object -Unique)
    foreach ($id in $uniqueProvided) {
      $null = $script:dependencyMapProvidedIdsByJar[$jarKey].Add($id)
      $key = $id.ToLowerInvariant()
      if (-not $script:dependencyMapByModId.ContainsKey($key)) {
        $script:dependencyMapByModId[$key] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
      }
      $null = $script:dependencyMapByModId[$key].Add($jarName)
    }
  }
}

function Get-DependentModCountsFromDependencyMap {
  <#
  .SYNOPSIS
  Builds a jarName->dependentCount map from an external dependency map.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$DependencyMap,
    [Parameter(Mandatory = $false)]
    [ValidateSet("RequiredOnly", "All")]
    [string]$CountMode = "RequiredOnly"
  )

  if ($null -eq $DependencyMap) { return @{} }

  $incomingById = @{}
  $providedByJar = @{}

  $edges = @($DependencyMap.Dependencies)
  foreach ($edge in $edges) {
    if ($null -eq $edge) { continue }
    $depId = [string]$edge.DependencyId
    $fromId = [string]$edge.FromModId
    if ([string]::IsNullOrWhiteSpace($depId) -or [string]::IsNullOrWhiteSpace($fromId)) { continue }

    $isRequired = [bool]$edge.IsRequired
    if ($CountMode -eq "RequiredOnly" -and (-not $isRequired)) { continue }

    $depKey = $depId.ToLowerInvariant()
    if (-not $incomingById.ContainsKey($depKey)) {
      $incomingById[$depKey] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    $null = $incomingById[$depKey].Add($fromId)
  }

  $mods = @($DependencyMap.Mods)
  foreach ($mod in $mods) {
    if ($null -eq $mod) { continue }
    $jarName = [string]$mod.JarName
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
    $jarKey = $jarName.ToLowerInvariant()
    if (-not $providedByJar.ContainsKey($jarKey)) {
      $providedByJar[$jarKey] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    if ($mod.PSObject.Properties.Name -contains "ModId") {
      $modId = [string]$mod.ModId
      if (-not [string]::IsNullOrWhiteSpace($modId)) {
        $null = $providedByJar[$jarKey].Add($modId)
      }
    }
    if ($mod.PSObject.Properties.Name -contains "ProvidedModIds") {
      foreach ($item in $mod.ProvidedModIds) {
        $value = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($value)) {
          $null = $providedByJar[$jarKey].Add($value)
        }
      }
    }
  }

  $result = @{}
  foreach ($jarKey in $providedByJar.Keys) {
    $ids = @($providedByJar[$jarKey])
    if (-not $ids -or $ids.Count -eq 0) {
      $result[$jarKey] = [pscustomobject]@{
        DependentCount = -1
        Known = $false
        ProvidedModIds = @()
      }
      continue
    }

    $max = 0
    foreach ($id in $ids) {
      $idKey = [string]$id
      if ($incomingById.ContainsKey($idKey.ToLowerInvariant())) {
        $count = $incomingById[$idKey.ToLowerInvariant()].Count
        if ($count -gt $max) { $max = $count }
      }
    }
    $result[$jarKey] = [pscustomobject]@{
      DependentCount = [int]$max
      Known = $true
      ProvidedModIds = @($ids)
    }
  }

  return $result
}

function Get-DependencyMapFromSource {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScanPath
  )

  if ([string]::IsNullOrWhiteSpace($DependencyMapSource)) {
    return $null
  }

  if ($DependencyMapSource -eq "Internal") {
    return $null
  }

  if ($DependencyMapSource -eq "File") {
    $jsonPath = $DependencyMapJsonPath
    if ([string]::IsNullOrWhiteSpace($jsonPath)) {
      $jsonPath = Join-Path -Path $PSScriptRoot -ChildPath "..\reports\jar-dependency-map.json"
    }
    return Read-DependencyMapJson -JsonPath $jsonPath
  }

  $toolPath = $DependencyMapToolPath
  if ([string]::IsNullOrWhiteSpace($toolPath)) {
    $toolPath = Join-Path -Path $PSScriptRoot -ChildPath "..\tools\Analyze-JarDependencyMap.ps1"
  }
  if (-not (Test-Path -LiteralPath $toolPath)) {
    Write-Host ("Warning: dependency map tool not found: {0}" -f $toolPath) -ForegroundColor Yellow
    return $null
  }

  $outDir = $DependencyMapOutDir
  if ([string]::IsNullOrWhiteSpace($outDir)) {
    $outDir = Join-Path -Path $PSScriptRoot -ChildPath "..\reports"
  }
  New-DirectoryIfMissing -DirPath $outDir

  try {
    & $toolPath -ScanPath $ScanPath -NoRecurse -WriteFiles:$true -OutDir $outDir -TopDependencies 0
  } catch {
    Write-Host ("Warning: dependency map tool failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    return $null
  }

  $jsonPath = Join-Path -Path $outDir -ChildPath "jar-dependency-map.json"
  return Read-DependencyMapJson -JsonPath $jsonPath
}

# * Computes dependency-aware tier from dependent count and known flag.
function Get-DependencyAwareTier {
  param(
    [Parameter(Mandatory = $true)]
    [int]$DependentCount,
    [Parameter(Mandatory = $true)]
    [bool]$Known
  )

  if (-not $Known) { return 4 }
  if ($DependentCount -le 0) { return 1 }
  if ($DependentCount -le $DependencyAwareTier2MaxDependents) { return 2 }
  if ($DependentCount -le $DependencyAwareTier3MaxDependents) { return 3 }
  return 4
}

function Get-DependencyAwareJarPriorityInfo {
  <#
  .SYNOPSIS
  Returns dependency-aware priority metadata for a jar name.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarName
  )

  $fallbackTier = if ([bool]$DependencyAwareTreatUnknownAsCore) { 4 } else { 1 }
  if ([string]::IsNullOrWhiteSpace($JarName)) {
    return [pscustomobject]@{
      Tier = $fallbackTier
      DependentCount = -1
      Known = $false
      DependentCountSort = [int]::MaxValue
    }
  }

  $jarKey = $JarName.ToLowerInvariant()
  $tier = $fallbackTier
  $depCount = -1
  $known = $false

  $tierVar = Get-Variable -Name "dependencyAwareTierByJarName" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $tierVar -and $tierVar.Value -is [hashtable]) {
    $tierMap = [hashtable]$tierVar.Value
    if ($tierMap.ContainsKey($jarKey)) {
      $tier = [int]$tierMap[$jarKey]
    }
  }

  $statsVar = Get-Variable -Name "dependencyAwareStatsByJarName" -Scope Script -ErrorAction SilentlyContinue
  if ($null -ne $statsVar -and $statsVar.Value -is [hashtable]) {
    $statsMap = [hashtable]$statsVar.Value
    if ($statsMap.ContainsKey($jarKey)) {
      $stats = $statsMap[$jarKey]
      if ($null -ne $stats) {
        if ($stats.PSObject.Properties.Name -contains "DependentCount") {
          $depCount = [int]$stats.DependentCount
        }
        if ($stats.PSObject.Properties.Name -contains "Known") {
          $known = [bool]$stats.Known
        }
      }
    }
  }

  if (-not $known -and (-not [bool]$DependencyAwareTreatUnknownAsCore)) {
    $depCount = 0
    $known = $true
  }

  $depCountSort = if ($depCount -ge 0) { [int]$depCount } else { [int]::MaxValue }
  return [pscustomobject]@{
    Tier = [int]$tier
    DependentCount = [int]$depCount
    Known = [bool]$known
    DependentCountSort = $depCountSort
  }
}

# * Filters quick-isolate candidates to avoid core-tier mods early.
function Select-QuickIsolateJarsByTier {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Jars,
    [Parameter(Mandatory = $false)]
    [string]$Context = "",
    [Parameter(Mandatory = $false)]
    [int]$MaxResults = 0
  )

  if (-not $Jars -or $Jars.Count -eq 0) { return @() }
  if (-not $UseDependencyAwareOrdering) {
    if ($MaxResults -gt 0 -and $Jars.Count -gt $MaxResults) {
      $head = @()
      for ($i = 0; $i -lt $Jars.Count; $i++) {
        if ($i -ge $MaxResults) { break }
        $head += @($Jars[$i])
      }
      return ,@($head)
    }
    return ,@($Jars)
  }
  $effectiveMaxTier = $DependencyAwareQuickIsolateMaxTier
  if ($script:currentDependencyTier -gt 0 -and $effectiveMaxTier -gt 0) {
    $effectiveMaxTier = [Math]::Min($effectiveMaxTier, $script:currentDependencyTier)
  }
  if ($effectiveMaxTier -le 0) { return ,@($Jars) }
  if (-not $script:dependencyAwareTierByJarName -or $script:dependencyAwareTierByJarName.Count -eq 0) {
    return ,@($Jars)
  }

  $allowed = New-Object System.Collections.Generic.List[object]
  $skipped = New-Object System.Collections.Generic.List[string]
  foreach ($jar in $Jars) {
    if ($null -eq $jar) { continue }
    $jarName = [string]$jar.Name
    if ([string]::IsNullOrWhiteSpace($jarName)) { continue }
    $priority = Get-DependencyAwareJarPriorityInfo -JarName $jarName
    $tier = [int]$priority.Tier

    if ($tier -le $effectiveMaxTier) {
      $allowed.Add([pscustomobject]@{
          Jar = $jar
          Tier = [int]$priority.Tier
          DependentCount = [int]$priority.DependentCount
          DependentCountSort = [int]$priority.DependentCountSort
          Known = [bool]$priority.Known
        }) | Out-Null
    } else {
      $skipped.Add($jarName) | Out-Null
    }
  }

  if ($skipped.Count -gt 0) {
    $contextLabel = if ([string]::IsNullOrWhiteSpace($Context)) { "" } else { " ({0})" -f $Context }
    $skippedLabel = ($skipped | Sort-Object -Unique) -join ", "
    Write-Host ("Fast Isolation skipped core-tier mods{0}: {1}" -f $contextLabel, $skippedLabel) -ForegroundColor Gray
  }

  if ($allowed.Count -eq 0) { return @() }

  $ordered = @($allowed.ToArray() | Sort-Object -Property `
      @{ Expression = { $_.Tier }; Ascending = $true }, `
      @{ Expression = { $_.DependentCountSort }; Ascending = $true }, `
      @{ Expression = { if ($null -ne $_.Jar -and $null -ne $_.Jar.PSObject.Properties["LastWriteTime"]) { [datetime]$_.Jar.LastWriteTime } else { [datetime]::MinValue } }; Descending = $true }, `
      @{ Expression = { if ($null -ne $_.Jar) { [string]$_.Jar.Name } else { "" } }; Ascending = $true })

  $decisionVar = Get-Variable -Name "dependencyPriorityDecisionByJarName" -Scope Script -ErrorAction SilentlyContinue
  $decisionMap = $null
  if ($null -ne $decisionVar -and $decisionVar.Value -is [hashtable]) {
    $decisionMap = [hashtable]$decisionVar.Value
  }

  $resultItems = $ordered
  if ($MaxResults -gt 0 -and $ordered.Count -gt $MaxResults) {
    $selectedItems = @()
    $deferredItems = @()
    for ($i = 0; $i -lt $ordered.Count; $i++) {
      if ($i -lt $MaxResults) {
        $selectedItems += @($ordered[$i])
      } else {
        $deferredItems += @($ordered[$i])
      }
    }
    $selectedLabel = ($selectedItems | ForEach-Object { [string]$_.Jar.Name }) -join ", "
    $deferredLabel = ($deferredItems | ForEach-Object { [string]$_.Jar.Name }) -join ", "
    $contextLabel = if ([string]::IsNullOrWhiteSpace($Context)) { "" } else { " ({0})" -f $Context }
    Write-Host ("Priority choice{0}: isolate {1}; defer {2}" -f $contextLabel, $selectedLabel, $deferredLabel) -ForegroundColor Gray
    $resultItems = $selectedItems

    if ($null -ne $decisionMap) {
      foreach ($item in $selectedItems) {
        if ($null -eq $item -or $null -eq $item.Jar) { continue }
        $name = [string]$item.Jar.Name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $reason = "dependency-priority: selected tier={0}, dependents={1}; deferred: {2}" -f $item.Tier, $item.DependentCount, $deferredLabel
        $decisionMap[$name.ToLowerInvariant()] = [pscustomobject]@{
          Context = $Context
          Tier = [int]$item.Tier
          DependentCount = [int]$item.DependentCount
          Known = [bool]$item.Known
          DeferredJars = @($deferredItems | ForEach-Object { [string]$_.Jar.Name })
          Reason = $reason
        }
      }
    }
  } elseif ($null -ne $decisionMap) {
    foreach ($item in $resultItems) {
      if ($null -eq $item -or $null -eq $item.Jar) { continue }
      $name = [string]$item.Jar.Name
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      $reason = "dependency-priority: selected tier={0}, dependents={1}" -f $item.Tier, $item.DependentCount
      $decisionMap[$name.ToLowerInvariant()] = [pscustomobject]@{
        Context = $Context
        Tier = [int]$item.Tier
        DependentCount = [int]$item.DependentCount
        Known = [bool]$item.Known
        DeferredJars = @()
        Reason = $reason
      }
    }
  }

  return ,@($resultItems | ForEach-Object { $_.Jar })
}
