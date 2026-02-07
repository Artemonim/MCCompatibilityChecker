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
        "mc"        = $true
        "minecraft" = $true
        "mod"       = $true
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
    $jars = Get-ChildItem -LiteralPath $dir -Filter "*.jar" -File -ErrorAction SilentlyContinue
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
    $jars = Get-ChildItem -LiteralPath $dir -Filter "*.jar" -File -ErrorAction SilentlyContinue
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
    $jars = Get-ChildItem -LiteralPath $dir -Filter "*.jar" -File -ErrorAction SilentlyContinue
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

  $entry = $Zip.Entries | Where-Object { $_.FullName -eq $EntryPath } | Select-Object -First 1
  if (-not $entry) {
    return $null
  }

  $stream = $null
  $reader = $null
  try {
    $stream = $entry.Open()
    $reader = [System.IO.StreamReader]::new($stream)
    return $reader.ReadToEnd()
  } finally {
    if ($reader) { $reader.Dispose() }
    if ($stream) { $stream.Dispose() }
  }
}

function Get-FabricDependencyRecordsFromModJson {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$ModJson
  )

  $deps = New-Object System.Collections.Generic.List[object]
  $depBlocks = @("depends", "suggests", "recommends", "breaks", "conflicts")
  foreach ($block in $depBlocks) {
    if (-not ($ModJson.PSObject.Properties.Name -contains $block)) { continue }
    $blockValue = $ModJson.$block
    if ($null -eq $blockValue) { continue }

    if ($blockValue -is [pscustomobject]) {
      foreach ($prop in $blockValue.PSObject.Properties) {
        $depId = [string]$prop.Name
        if (-not [string]::IsNullOrWhiteSpace($depId)) {
          $deps.Add([pscustomobject]@{ DependencyId = $depId; Kind = $block }) | Out-Null
        }
      }
      continue
    }

    if ($blockValue -is [System.Collections.IEnumerable] -and -not ($blockValue -is [string])) {
      foreach ($item in $blockValue) {
        if ($item -is [string]) {
          $depId = [string]$item
          if (-not [string]::IsNullOrWhiteSpace($depId)) {
            $deps.Add([pscustomobject]@{ DependencyId = $depId; Kind = $block }) | Out-Null
          }
        } elseif ($item -is [pscustomobject]) {
          $depId = ""
          if ($item.PSObject.Properties.Name -contains "id") {
            $depId = [string]$item.id
          }
          if (-not [string]::IsNullOrWhiteSpace($depId)) {
            $deps.Add([pscustomobject]@{ DependencyId = $depId; Kind = $block }) | Out-Null
          }
        }
      }
    }
  }

  return ,@($deps.ToArray())
}

function Get-QuiltDependencyRecordsFromLoader {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Loader
  )

  $deps = New-Object System.Collections.Generic.List[object]
  $depBlocks = @("depends", "suggests", "recommends", "breaks", "conflicts")
  foreach ($block in $depBlocks) {
    if (-not ($Loader.PSObject.Properties.Name -contains $block)) { continue }
    $blockValue = $Loader.$block
    if ($null -eq $blockValue) { continue }

    if ($blockValue -is [System.Collections.IEnumerable] -and -not ($blockValue -is [string])) {
      foreach ($item in $blockValue) {
        if ($item -is [pscustomobject]) {
          $depId = ""
          if ($item.PSObject.Properties.Name -contains "id") {
            $depId = [string]$item.id
          }
          if (-not [string]::IsNullOrWhiteSpace($depId)) {
            $deps.Add([pscustomobject]@{ DependencyId = $depId; Kind = $block }) | Out-Null
          }
        }
      }
    }
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

  $mods = New-Object System.Collections.Generic.List[object]
  $dependencies = New-Object System.Collections.Generic.List[object]
  $currentSection = ""
  $currentMod = $null
  $currentDep = $null

  $lines = $TomlText -split "(`r`n|`n|`r)"
  foreach ($line in $lines) {
    $trim = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trim)) { continue }

    if ($trim -match '^\[\[mods\]\]') {
      if ($currentMod) {
        $mods.Add($currentMod) | Out-Null
      }
      $currentMod = [ordered]@{
        ModId = ""
      }
      $currentSection = "mods"
      continue
    }

    if ($trim -match '^\[\[dependencies\.([^\]]+)\]\]') {
      if ($currentDep) {
        $dependencies.Add($currentDep) | Out-Null
      }
      $currentDep = [ordered]@{
        OwnerModId = [string]$Matches[1]
        DependencyId = ""
        Mandatory = $null
      }
      $currentSection = "dependencies"
      continue
    }

    if ($currentSection -eq "mods" -and $currentMod) {
      if ($trim -match '^modId\s*=\s*"(.*)"') {
        $currentMod.ModId = [string]$Matches[1]
        continue
      }
      if ($trim -match "^modId\s*=\s*'(.*)'") {
        $currentMod.ModId = [string]$Matches[1]
        continue
      }
    }

    if ($currentSection -eq "dependencies" -and $currentDep) {
      if ($trim -match '^modId\s*=\s*"(.*)"') {
        $currentDep.DependencyId = [string]$Matches[1]
        continue
      }
      if ($trim -match "^modId\s*=\s*'(.*)'") {
        $currentDep.DependencyId = [string]$Matches[1]
        continue
      }
      if ($trim -match '^mandatory\s*=\s*(true|false)') {
        $currentDep.Mandatory = [System.Convert]::ToBoolean($Matches[1])
        continue
      }
    }
  }

  if ($currentMod) {
    $mods.Add($currentMod) | Out-Null
  }
  if ($currentDep) {
    $dependencies.Add($currentDep) | Out-Null
  }

  return [pscustomobject]@{
    Mods = $mods
    Dependencies = $dependencies
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

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = $null
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)

    $fabricText = Get-JarZipEntryText -Zip $zip -EntryPath "fabric.mod.json"
    if ($fabricText) {
      $modJson = $null
      try {
        $modJson = $fabricText | ConvertFrom-Json -ErrorAction Stop
      } catch {
        return $null
      }

      $mainId = ""
      if ($modJson.PSObject.Properties.Name -contains "id") {
        $mainId = [string]$modJson.id
      }
      if ([string]::IsNullOrWhiteSpace($mainId)) {
        $mainId = [System.IO.Path]::GetFileNameWithoutExtension($JarPath)
      }

      $provided = New-Object System.Collections.Generic.List[string]
      if (-not [string]::IsNullOrWhiteSpace($mainId)) {
        $provided.Add($mainId) | Out-Null
      }
      if ($modJson.PSObject.Properties.Name -contains "provides" -and $null -ne $modJson.provides) {
        if ($modJson.provides -is [string]) {
          $v = [string]$modJson.provides
          if (-not [string]::IsNullOrWhiteSpace($v)) { $provided.Add($v) | Out-Null }
        } elseif ($modJson.provides -is [System.Collections.IDictionary]) {
          foreach ($key in $modJson.provides.Keys) {
            $v = [string]$key
            if (-not [string]::IsNullOrWhiteSpace($v)) { $provided.Add($v) | Out-Null }
          }
        } elseif ($modJson.provides -is [pscustomobject]) {
          foreach ($prop in $modJson.provides.PSObject.Properties) {
            $v = [string]$prop.Name
            if (-not [string]::IsNullOrWhiteSpace($v)) { $provided.Add($v) | Out-Null }
          }
        } elseif ($modJson.provides -is [System.Collections.IEnumerable]) {
          foreach ($p in $modJson.provides) {
            $v = [string]$p
            if (-not [string]::IsNullOrWhiteSpace($v)) { $provided.Add($v) | Out-Null }
          }
        }
      }

      $edges = New-Object System.Collections.Generic.List[object]
      $depRecords = @(Get-FabricDependencyRecordsFromModJson -ModJson $modJson)
      foreach ($dep in $depRecords) {
        $depId = [string]$dep.DependencyId
        if ([string]::IsNullOrWhiteSpace($depId)) { continue }
        $edges.Add([pscustomobject]@{
            FromModId = $mainId
            DependencyId = $depId
            IsRequired = ([string]$dep.Kind -eq "depends")
          }) | Out-Null
      }

      return [pscustomobject]@{
        Loader = "Fabric"
        ProvidedModIds = @($provided.ToArray())
        DependencyEdges = @($edges.ToArray())
      }
    }

    $quiltText = Get-JarZipEntryText -Zip $zip -EntryPath "quilt.mod.json"
    if ($quiltText) {
      $modJson = $null
      try {
        $modJson = $quiltText | ConvertFrom-Json -ErrorAction Stop
      } catch {
        return $null
      }

      $loader = $modJson.quilt_loader
      if ($null -eq $loader) {
        return $null
      }

      $mainId = ""
      if ($loader.PSObject.Properties.Name -contains "id") {
        $mainId = [string]$loader.id
      }
      if ([string]::IsNullOrWhiteSpace($mainId)) {
        $mainId = [System.IO.Path]::GetFileNameWithoutExtension($JarPath)
      }

      $provided = New-Object System.Collections.Generic.List[string]
      if (-not [string]::IsNullOrWhiteSpace($mainId)) {
        $provided.Add($mainId) | Out-Null
      }
      if ($loader.PSObject.Properties.Name -contains "provides" -and $null -ne $loader.provides) {
        if ($loader.provides -is [string]) {
          $v = [string]$loader.provides
          if (-not [string]::IsNullOrWhiteSpace($v)) { $provided.Add($v) | Out-Null }
        } elseif ($loader.provides -is [System.Collections.IDictionary]) {
          foreach ($key in $loader.provides.Keys) {
            $v = [string]$key
            if (-not [string]::IsNullOrWhiteSpace($v)) { $provided.Add($v) | Out-Null }
          }
        } elseif ($loader.provides -is [pscustomobject]) {
          foreach ($prop in $loader.provides.PSObject.Properties) {
            $v = [string]$prop.Name
            if (-not [string]::IsNullOrWhiteSpace($v)) { $provided.Add($v) | Out-Null }
          }
        } elseif ($loader.provides -is [System.Collections.IEnumerable]) {
          foreach ($p in $loader.provides) {
            $v = [string]$p
            if (-not [string]::IsNullOrWhiteSpace($v)) { $provided.Add($v) | Out-Null }
          }
        }
      }

      $edges = New-Object System.Collections.Generic.List[object]
      $depRecords = @(Get-QuiltDependencyRecordsFromLoader -Loader $loader)
      foreach ($dep in $depRecords) {
        $depId = [string]$dep.DependencyId
        if ([string]::IsNullOrWhiteSpace($depId)) { continue }
        $edges.Add([pscustomobject]@{
            FromModId = $mainId
            DependencyId = $depId
            IsRequired = ([string]$dep.Kind -eq "depends")
          }) | Out-Null
      }

      return [pscustomobject]@{
        Loader = "Quilt"
        ProvidedModIds = @($provided.ToArray())
        DependencyEdges = @($edges.ToArray())
      }
    }

    $tomlText = Get-JarZipEntryText -Zip $zip -EntryPath "META-INF/mods.toml"
    $loaderName = "Forge"
    if (-not $tomlText) {
      $tomlText = Get-JarZipEntryText -Zip $zip -EntryPath "META-INF/neoforge.mods.toml"
      if ($tomlText) {
        $loaderName = "NeoForge"
      }
    }

    if ($tomlText) {
      $parsed = ConvertFrom-ForgeToml -TomlText $tomlText

      $provided = New-Object System.Collections.Generic.List[string]
      foreach ($mod in $parsed.Mods) {
        $id = [string]$mod.ModId
        if (-not [string]::IsNullOrWhiteSpace($id)) {
          $provided.Add($id) | Out-Null
        }
      }

      $edges = New-Object System.Collections.Generic.List[object]
      foreach ($dep in $parsed.Dependencies) {
        $fromId = [string]$dep.OwnerModId
        if ([string]::IsNullOrWhiteSpace($fromId)) {
          $fromId = [System.IO.Path]::GetFileNameWithoutExtension($JarPath)
        }
        $depId = [string]$dep.DependencyId
        if ([string]::IsNullOrWhiteSpace($depId)) { continue }
        $edges.Add([pscustomobject]@{
            FromModId = $fromId
            DependencyId = $depId
            IsRequired = ([bool]($dep.Mandatory -eq $true))
          }) | Out-Null
      }

      return [pscustomobject]@{
        Loader = $loaderName
        ProvidedModIds = @($provided.ToArray())
        DependencyEdges = @($edges.ToArray())
      }
    }

    return $null
  } catch {
    return $null
  } finally {
    if ($zip) { $zip.Dispose() }
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

  $jarFiles = Get-ChildItem -LiteralPath $ModsDir -Filter "*.jar" -File -ErrorAction SilentlyContinue
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

# * Filters quick-isolate candidates to avoid core-tier mods early.
function Select-QuickIsolateJarsByTier {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Jars,
    [Parameter(Mandatory = $false)]
    [string]$Context = ""
  )

  if (-not $Jars -or $Jars.Count -eq 0) { return @() }
  if (-not $UseDependencyAwareOrdering) { return ,@($Jars) }
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
    $key = $jarName.ToLowerInvariant()

    $tier = 4
    if ($script:dependencyAwareTierByJarName.ContainsKey($key)) {
      $tier = [int]$script:dependencyAwareTierByJarName[$key]
    } elseif (-not [bool]$DependencyAwareTreatUnknownAsCore) {
      $tier = 1
    }

    if ($tier -le $effectiveMaxTier) {
      $allowed.Add($jar) | Out-Null
    } else {
      $skipped.Add($jarName) | Out-Null
    }
  }

  if ($skipped.Count -gt 0) {
    $contextLabel = if ([string]::IsNullOrWhiteSpace($Context)) { "" } else { " ({0})" -f $Context }
    $skippedLabel = ($skipped | Sort-Object -Unique) -join ", "
    Write-Host ("Быстрая изоляция пропустила моды уровня core{0}: {1}" -f $contextLabel, $skippedLabel) -ForegroundColor Gray
  }

  return ,@($allowed.ToArray())
}
