function ConvertTo-McccVersionRangeString {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object]$Value
  )

  if ($null -eq $Value) { return "" }
  if ($Value -is [string]) { return [string]$Value }
  if ($Value -is [System.Collections.IEnumerable]) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Value) {
      if ($null -eq $item) { continue }
      $text = [string]$item
      if ([string]::IsNullOrWhiteSpace($text)) { continue }
      $parts.Add($text) | Out-Null
    }
    if ($parts.Count -eq 0) { return "" }
    return ($parts.ToArray() -join ",")
  }
  return [string]$Value
}

function Get-McccObjectPropertyValue {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object]$Object,
    [Parameter(Mandatory = $true)]
    [string]$PropertyName
  )

  if ($null -eq $Object) { return $null }
  if ([string]::IsNullOrWhiteSpace($PropertyName)) { return $null }

  if ($Object -is [System.Collections.IDictionary]) {
    foreach ($key in $Object.Keys) {
      if ([string]::Equals([string]$key, $PropertyName, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Object[$key]
      }
    }
    return $null
  }

  foreach ($prop in $Object.PSObject.Properties) {
    if ([string]::Equals([string]$prop.Name, $PropertyName, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $prop.Value
    }
  }
  return $null
}

function Get-McccObjectPropertyString {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object]$Object,
    [Parameter(Mandatory = $true)]
    [string]$PropertyName
  )

  $value = Get-McccObjectPropertyValue -Object $Object -PropertyName $PropertyName
  if ($null -eq $value) { return "" }
  return [string]$value
}

function Get-McccZipEntryByPath {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.Compression.ZipArchive]$Zip,
    [Parameter(Mandatory = $true)]
    [string]$EntryPath
  )

  if ([string]::IsNullOrWhiteSpace($EntryPath)) { return $null }
  $target = $EntryPath.Replace("\", "/").ToLowerInvariant()
  foreach ($entry in @($Zip.Entries)) {
    if ($null -eq $entry) { continue }
    $entryName = [string]$entry.FullName
    if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
    if ($entryName.Replace("\", "/").ToLowerInvariant() -eq $target) {
      return $entry
    }
  }
  return $null
}

function Get-McccJarEntryText {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.Compression.ZipArchive]$Zip,
    [Parameter(Mandatory = $true)]
    [string]$EntryPath
  )

  $entry = Get-McccZipEntryByPath -Zip $Zip -EntryPath $EntryPath
  if ($null -eq $entry) { return $null }

  $reader = $null
  try {
    $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8, $true)
    return [string]$reader.ReadToEnd()
  } finally {
    if ($null -ne $reader) { $reader.Dispose() }
  }
}

function Get-McccJarEntryJson {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.Compression.ZipArchive]$Zip,
    [Parameter(Mandatory = $true)]
    [string]$EntryPath
  )

  $jsonText = Get-McccJarEntryText -Zip $Zip -EntryPath $EntryPath
  if ([string]::IsNullOrWhiteSpace($jsonText)) { return $null }
  return ($jsonText | ConvertFrom-Json -ErrorAction Stop)
}

function Get-McccProvidedIdList {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object]$ProvidesValue
  )

  $provided = [System.Collections.Generic.List[string]]::new()
  if ($null -eq $ProvidesValue) { return @() }

  if ($ProvidesValue -is [string]) {
    if (-not [string]::IsNullOrWhiteSpace([string]$ProvidesValue)) {
      $provided.Add(([string]$ProvidesValue).Trim()) | Out-Null
    }
  } elseif ($ProvidesValue -is [System.Collections.IDictionary]) {
    foreach ($key in $ProvidesValue.Keys) {
      $value = [string]$key
      if ([string]::IsNullOrWhiteSpace($value)) { continue }
      $provided.Add($value.Trim()) | Out-Null
    }
  } elseif ($ProvidesValue -is [System.Collections.IEnumerable] -and -not ($ProvidesValue -is [string])) {
    foreach ($item in $ProvidesValue) {
      if ($null -eq $item) { continue }
      if ($item -is [string]) {
        $value = [string]$item
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $provided.Add($value.Trim()) | Out-Null
        continue
      }
      $itemId = Get-McccObjectPropertyString -Object $item -PropertyName "id"
      if (-not [string]::IsNullOrWhiteSpace($itemId)) {
        $provided.Add($itemId.Trim()) | Out-Null
      }
    }
  } else {
    foreach ($prop in $ProvidesValue.PSObject.Properties) {
      $value = [string]$prop.Name
      if ([string]::IsNullOrWhiteSpace($value)) { continue }
      $provided.Add($value.Trim()) | Out-Null
    }
  }

  if ($provided.Count -eq 0) { return @() }
  return ,@($provided.ToArray() | Sort-Object -Unique)
}

function New-McccDependencyRecord {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModId,
    [Parameter(Mandatory = $false)]
    [string]$VersionRange = "",
    [Parameter(Mandatory = $false)]
    [string]$Kind = "",
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [Nullable[bool]]$IsRequired = $null,
    [Parameter(Mandatory = $false)]
    [string]$Side = "",
    [Parameter(Mandatory = $false)]
    [string]$Ordering = "",
    [Parameter(Mandatory = $false)]
    [string]$OwnerModId = ""
  )

  return [pscustomobject]@{
    ModId        = $ModId
    VersionRange = $VersionRange
    Kind         = $Kind
    IsRequired   = $IsRequired
    Side         = $Side
    Ordering     = $Ordering
    OwnerModId   = $OwnerModId
  }
}

function Get-McccFabricDependencyList {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$ModJson,
    [Parameter(Mandatory = $false)]
    [string]$OwnerModId = ""
  )

  $deps = New-Object System.Collections.Generic.List[object]
  $depBlocks = @("depends", "suggests", "recommends", "breaks", "conflicts")
  foreach ($block in $depBlocks) {
    $blockValue = Get-McccObjectPropertyValue -Object $ModJson -PropertyName $block
    if ($null -eq $blockValue) { continue }

    if ($blockValue -is [System.Collections.IDictionary]) {
      foreach ($key in $blockValue.Keys) {
        $depId = [string]$key
        if ([string]::IsNullOrWhiteSpace($depId)) { continue }
        $deps.Add((New-McccDependencyRecord `
              -ModId $depId `
              -VersionRange (ConvertTo-McccVersionRangeString -Value $blockValue[$key]) `
              -Kind $block `
              -IsRequired ([bool]($block -eq "depends")) `
              -OwnerModId $OwnerModId)) | Out-Null
      }
      continue
    }

    if ($blockValue -is [pscustomobject]) {
      foreach ($prop in $blockValue.PSObject.Properties) {
        $depId = [string]$prop.Name
        if ([string]::IsNullOrWhiteSpace($depId)) { continue }
        $deps.Add((New-McccDependencyRecord `
              -ModId $depId `
              -VersionRange (ConvertTo-McccVersionRangeString -Value $prop.Value) `
              -Kind $block `
              -IsRequired ([bool]($block -eq "depends")) `
              -OwnerModId $OwnerModId)) | Out-Null
      }
      continue
    }

    if ($blockValue -is [System.Collections.IEnumerable] -and -not ($blockValue -is [string])) {
      foreach ($item in $blockValue) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
          $depId = [string]$item
          if ([string]::IsNullOrWhiteSpace($depId)) { continue }
          $deps.Add((New-McccDependencyRecord `
                -ModId $depId `
                -VersionRange "" `
                -Kind $block `
                -IsRequired ([bool]($block -eq "depends")) `
                -OwnerModId $OwnerModId)) | Out-Null
          continue
        }

        $depId = Get-McccObjectPropertyString -Object $item -PropertyName "id"
        if ([string]::IsNullOrWhiteSpace($depId)) {
          $depId = Get-McccObjectPropertyString -Object $item -PropertyName "modId"
        }
        if ([string]::IsNullOrWhiteSpace($depId)) { continue }

        $versionRange = ConvertTo-McccVersionRangeString -Value (Get-McccObjectPropertyValue -Object $item -PropertyName "version")
        if ([string]::IsNullOrWhiteSpace($versionRange)) {
          $versionRange = ConvertTo-McccVersionRangeString -Value (Get-McccObjectPropertyValue -Object $item -PropertyName "versions")
        }

        $deps.Add((New-McccDependencyRecord `
              -ModId $depId `
              -VersionRange $versionRange `
              -Kind $block `
              -IsRequired ([bool]($block -eq "depends")) `
              -OwnerModId $OwnerModId)) | Out-Null
      }
      continue
    }

    if ($blockValue -is [string]) {
      $depId = [string]$blockValue
      if (-not [string]::IsNullOrWhiteSpace($depId)) {
        $deps.Add((New-McccDependencyRecord `
              -ModId $depId `
              -VersionRange "" `
              -Kind $block `
              -IsRequired ([bool]($block -eq "depends")) `
              -OwnerModId $OwnerModId)) | Out-Null
      }
    }
  }

  if ($deps.Count -eq 0) { return @() }
  return ,@($deps.ToArray())
}

function Get-McccQuiltDependencyList {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Loader,
    [Parameter(Mandatory = $false)]
    [string]$OwnerModId = ""
  )

  $deps = New-Object System.Collections.Generic.List[object]
  $depBlocks = @("depends", "suggests", "recommends", "breaks", "conflicts")
  foreach ($block in $depBlocks) {
    $blockValue = Get-McccObjectPropertyValue -Object $Loader -PropertyName $block
    if ($null -eq $blockValue) { continue }

    if ($blockValue -is [System.Collections.IDictionary]) {
      foreach ($key in $blockValue.Keys) {
        $depId = [string]$key
        if ([string]::IsNullOrWhiteSpace($depId)) { continue }
        $deps.Add((New-McccDependencyRecord `
              -ModId $depId `
              -VersionRange (ConvertTo-McccVersionRangeString -Value $blockValue[$key]) `
              -Kind $block `
              -IsRequired ([bool]($block -eq "depends")) `
              -OwnerModId $OwnerModId)) | Out-Null
      }
      continue
    }

    if ($blockValue -is [System.Collections.IEnumerable] -and -not ($blockValue -is [string])) {
      foreach ($item in $blockValue) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
          $depId = [string]$item
          if ([string]::IsNullOrWhiteSpace($depId)) { continue }
          $deps.Add((New-McccDependencyRecord `
                -ModId $depId `
                -VersionRange "" `
                -Kind $block `
                -IsRequired ([bool]($block -eq "depends")) `
                -OwnerModId $OwnerModId)) | Out-Null
          continue
        }

        $depId = Get-McccObjectPropertyString -Object $item -PropertyName "id"
        if ([string]::IsNullOrWhiteSpace($depId)) {
          $depId = Get-McccObjectPropertyString -Object $item -PropertyName "modId"
        }
        if ([string]::IsNullOrWhiteSpace($depId)) { continue }

        $versionRange = ConvertTo-McccVersionRangeString -Value (Get-McccObjectPropertyValue -Object $item -PropertyName "versions")
        if ([string]::IsNullOrWhiteSpace($versionRange)) {
          $versionRange = ConvertTo-McccVersionRangeString -Value (Get-McccObjectPropertyValue -Object $item -PropertyName "version")
        }

        $deps.Add((New-McccDependencyRecord `
              -ModId $depId `
              -VersionRange $versionRange `
              -Kind $block `
              -IsRequired ([bool]($block -eq "depends")) `
              -OwnerModId $OwnerModId)) | Out-Null
      }
      continue
    }

    if ($blockValue -is [string]) {
      $depId = [string]$blockValue
      if (-not [string]::IsNullOrWhiteSpace($depId)) {
        $deps.Add((New-McccDependencyRecord `
              -ModId $depId `
              -VersionRange "" `
              -Kind $block `
              -IsRequired ([bool]($block -eq "depends")) `
              -OwnerModId $OwnerModId)) | Out-Null
      }
    }
  }

  if ($deps.Count -eq 0) { return @() }
  return ,@($deps.ToArray())
}

function ConvertFrom-McccForgeToml {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TomlText
  )

  $mods = New-Object System.Collections.Generic.List[object]
  $deps = New-Object System.Collections.Generic.List[object]
  $currentSection = ""
  $currentMod = $null
  $currentDep = $null

  $lines = $TomlText -split "(`r`n|`n|`r)"
  foreach ($line in $lines) {
    $trim = [string]$line
    if ([string]::IsNullOrWhiteSpace($trim)) { continue }
    $trim = $trim.Trim()

    if ($trim -match '^(?i)\[\[\s*mods\s*\]\]$') {
      if ($null -ne $currentMod) {
        $mods.Add([pscustomobject]$currentMod) | Out-Null
      }
      $currentMod = [ordered]@{
        ModId       = ""
        DisplayName = ""
        Version     = ""
      }
      $currentSection = "mods"
      continue
    }

    if ($trim -match '^(?i)\[\[\s*dependencies\.([^\]]+)\s*\]\]$') {
      if ($null -ne $currentDep) {
        $deps.Add([pscustomobject]$currentDep) | Out-Null
      }
      $currentDep = [ordered]@{
        OwnerModId   = [string]$Matches[1]
        ModId        = ""
        VersionRange = ""
        IsRequired   = $null
        Side         = ""
        Ordering     = ""
        Kind         = "dependency"
      }
      $currentSection = "dependencies"
      continue
    }

    if ($currentSection -eq "mods" -and $null -ne $currentMod) {
      if ($trim -match '^(?i)modId\s*=\s*"(.*)"$' -or $trim -match "^(?i)modId\s*=\s*'(.*)'$") {
        $currentMod.ModId = [string]$Matches[1]
        continue
      }
      if ($trim -match '^(?i)displayName\s*=\s*"(.*)"$' -or $trim -match "^(?i)displayName\s*=\s*'(.*)'$") {
        $currentMod.DisplayName = [string]$Matches[1]
        continue
      }
      if ($trim -match '^(?i)version\s*=\s*"(.*)"$' -or $trim -match "^(?i)version\s*=\s*'(.*)'$") {
        $currentMod.Version = [string]$Matches[1]
        continue
      }
    }

    if ($currentSection -eq "dependencies" -and $null -ne $currentDep) {
      if ($trim -match '^(?i)modId\s*=\s*"(.*)"$' -or $trim -match "^(?i)modId\s*=\s*'(.*)'$") {
        $currentDep.ModId = [string]$Matches[1]
        continue
      }
      if ($trim -match '^(?i)versionRange\s*=\s*"(.*)"$' -or $trim -match "^(?i)versionRange\s*=\s*'(.*)'$") {
        $currentDep.VersionRange = [string]$Matches[1]
        continue
      }
      if ($trim -match '^(?i)mandatory\s*=\s*(true|false)$') {
        $currentDep.IsRequired = [System.Convert]::ToBoolean($Matches[1])
        continue
      }
      if ($trim -match '^(?i)side\s*=\s*"(.*)"$' -or $trim -match "^(?i)side\s*=\s*'(.*)'$") {
        $currentDep.Side = [string]$Matches[1]
        continue
      }
      if ($trim -match '^(?i)ordering\s*=\s*"(.*)"$' -or $trim -match "^(?i)ordering\s*=\s*'(.*)'$") {
        $currentDep.Ordering = [string]$Matches[1]
        continue
      }
    }
  }

  if ($null -ne $currentMod) {
    $mods.Add([pscustomobject]$currentMod) | Out-Null
  }
  if ($null -ne $currentDep) {
    $deps.Add([pscustomobject]$currentDep) | Out-Null
  }

  return [pscustomobject]@{
    Mods         = @($mods.ToArray())
    Dependencies = @($deps.ToArray())
  }
}

function ConvertFrom-McccMcmodInfo {
  param(
    [Parameter(Mandatory = $true)]
    [string]$McmodInfoText,
    [Parameter(Mandatory = $false)]
    [string]$FallbackModId = ""
  )

  $result = New-Object System.Collections.Generic.List[object]
  if ([string]::IsNullOrWhiteSpace($McmodInfoText)) { return @() }

  $data = $null
  try {
    $data = $McmodInfoText | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return @()
  }

  $items = @()
  if ($data -is [System.Collections.IEnumerable] -and -not ($data -is [string])) {
    $items = @($data)
  } else {
    $items = @($data)
  }

  foreach ($item in $items) {
    if ($null -eq $item) { continue }
    $modId = Get-McccObjectPropertyString -Object $item -PropertyName "modid"
    if ([string]::IsNullOrWhiteSpace($modId)) {
      $modId = Get-McccObjectPropertyString -Object $item -PropertyName "id"
    }
    if ([string]::IsNullOrWhiteSpace($modId)) {
      $modId = [string]$FallbackModId
    }

    $displayName = Get-McccObjectPropertyString -Object $item -PropertyName "name"
    if ([string]::IsNullOrWhiteSpace($displayName)) {
      $displayName = $modId
    }

    $version = Get-McccObjectPropertyString -Object $item -PropertyName "version"
    if ([string]::IsNullOrWhiteSpace($version)) {
      $version = "Unknown"
    }

    $provided = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($modId)) {
      $provided.Add($modId) | Out-Null
    }
    $providedIds = @($provided.ToArray() | Sort-Object -Unique)

    $deps = New-Object System.Collections.Generic.List[object]
    $acceptedVersions = Get-McccObjectPropertyString -Object $item -PropertyName "acceptedMinecraftVersions"
    if ([string]::IsNullOrWhiteSpace($acceptedVersions)) {
      $acceptedVersions = Get-McccObjectPropertyString -Object $item -PropertyName "mcversion"
    }
    if (-not [string]::IsNullOrWhiteSpace($acceptedVersions)) {
      $deps.Add((New-McccDependencyRecord `
            -ModId "minecraft" `
            -VersionRange $acceptedVersions `
            -Kind "depends" `
            -IsRequired $true `
            -OwnerModId $modId)) | Out-Null
    }

    $result.Add([pscustomobject]@{
        ModId        = $modId
        DisplayName  = $displayName
        Version      = $version
        ProvidedIds  = $providedIds
        Dependencies = @($deps.ToArray())
        Loader       = "Legacy"
      }) | Out-Null
  }

  if ($result.Count -eq 0) { return @() }
  return ,@($result.ToArray())
}

function Get-McccJarMetadataFromZipArchive {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.Compression.ZipArchive]$Zip,
    [Parameter(Mandatory = $false)]
    [string]$JarPath = "",
    [Parameter(Mandatory = $false)]
    [bool]$ThrowOnParseError = $false
  )

  $fallbackModId = ""
  if (-not [string]::IsNullOrWhiteSpace($JarPath)) {
    $fallbackModId = [System.IO.Path]::GetFileNameWithoutExtension($JarPath)
  }

  $fabricEntry = Get-McccZipEntryByPath -Zip $Zip -EntryPath "fabric.mod.json"
  if ($null -ne $fabricEntry) {
    $modJson = $null
    try {
      $modJson = Get-McccJarEntryJson -Zip $Zip -EntryPath "fabric.mod.json"
    } catch {
      if ($ThrowOnParseError) { throw }
      return $null
    }
    if ($null -eq $modJson) { return $null }

    $modId = Get-McccObjectPropertyString -Object $modJson -PropertyName "id"
    if ([string]::IsNullOrWhiteSpace($modId)) { $modId = $fallbackModId }
    $displayName = Get-McccObjectPropertyString -Object $modJson -PropertyName "name"
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $modId }
    $version = Get-McccObjectPropertyString -Object $modJson -PropertyName "version"
    if ([string]::IsNullOrWhiteSpace($version)) { $version = "Unknown" }

    $provided = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($modId)) {
      $provided.Add($modId) | Out-Null
    }
    foreach ($item in @(Get-McccProvidedIdList -ProvidesValue (Get-McccObjectPropertyValue -Object $modJson -PropertyName "provides"))) {
      if ([string]::IsNullOrWhiteSpace([string]$item)) { continue }
      $provided.Add(([string]$item).Trim()) | Out-Null
    }
    $providedIds = @($provided.ToArray() | Sort-Object -Unique)
    $deps = @(Get-McccFabricDependencyList -ModJson $modJson -OwnerModId $modId)

    $record = [pscustomobject]@{
      ModId        = $modId
      DisplayName  = $displayName
      Version      = $version
      ProvidedIds  = $providedIds
      Dependencies = $deps
      Loader       = "Fabric"
    }
    return [pscustomobject]@{
      Loader            = "Fabric"
      Records           = @($record)
      DependencyRecords = $deps
      JarProvidedIds    = $providedIds
    }
  }

  $quiltEntry = Get-McccZipEntryByPath -Zip $Zip -EntryPath "quilt.mod.json"
  if ($null -ne $quiltEntry) {
    $modJson = $null
    try {
      $modJson = Get-McccJarEntryJson -Zip $Zip -EntryPath "quilt.mod.json"
    } catch {
      if ($ThrowOnParseError) { throw }
      return $null
    }
    if ($null -eq $modJson) { return $null }

    $loaderObject = Get-McccObjectPropertyValue -Object $modJson -PropertyName "quilt_loader"
    if ($null -eq $loaderObject) { return $null }

    $modId = Get-McccObjectPropertyString -Object $loaderObject -PropertyName "id"
    if ([string]::IsNullOrWhiteSpace($modId)) { $modId = $fallbackModId }
    $version = Get-McccObjectPropertyString -Object $loaderObject -PropertyName "version"
    if ([string]::IsNullOrWhiteSpace($version)) { $version = "Unknown" }

    $displayName = ""
    $loaderMeta = Get-McccObjectPropertyValue -Object $loaderObject -PropertyName "metadata"
    if ($null -ne $loaderMeta) {
      $displayName = Get-McccObjectPropertyString -Object $loaderMeta -PropertyName "name"
    }
    if ([string]::IsNullOrWhiteSpace($displayName)) {
      $rootMeta = Get-McccObjectPropertyValue -Object $modJson -PropertyName "metadata"
      $displayName = Get-McccObjectPropertyString -Object $rootMeta -PropertyName "name"
    }
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $modId }

    $provided = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($modId)) {
      $provided.Add($modId) | Out-Null
    }
    foreach ($item in @(Get-McccProvidedIdList -ProvidesValue (Get-McccObjectPropertyValue -Object $loaderObject -PropertyName "provides"))) {
      if ([string]::IsNullOrWhiteSpace([string]$item)) { continue }
      $provided.Add(([string]$item).Trim()) | Out-Null
    }
    $providedIds = @($provided.ToArray() | Sort-Object -Unique)
    $deps = @(Get-McccQuiltDependencyList -Loader $loaderObject -OwnerModId $modId)

    $record = [pscustomobject]@{
      ModId        = $modId
      DisplayName  = $displayName
      Version      = $version
      ProvidedIds  = $providedIds
      Dependencies = $deps
      Loader       = "Quilt"
    }
    return [pscustomobject]@{
      Loader            = "Quilt"
      Records           = @($record)
      DependencyRecords = $deps
      JarProvidedIds    = $providedIds
    }
  }

  $tomlText = Get-McccJarEntryText -Zip $Zip -EntryPath "META-INF/mods.toml"
  $loaderName = "Forge"
  if (-not $tomlText) {
    $tomlText = Get-McccJarEntryText -Zip $Zip -EntryPath "META-INF/neoforge.mods.toml"
    if ($tomlText) {
      $loaderName = "NeoForge"
    }
  }

  if ($tomlText) {
    $parsed = ConvertFrom-McccForgeToml -TomlText $tomlText
    $dependencyRecords = New-Object System.Collections.Generic.List[object]
    foreach ($dep in @($parsed.Dependencies)) {
      if ($null -eq $dep) { continue }
      $depId = [string]$dep.ModId
      if ([string]::IsNullOrWhiteSpace($depId)) { continue }
      $dependencyRecords.Add((New-McccDependencyRecord `
            -ModId $depId `
            -VersionRange ([string]$dep.VersionRange) `
            -Kind ([string]$dep.Kind) `
            -IsRequired $dep.IsRequired `
            -Side ([string]$dep.Side) `
            -Ordering ([string]$dep.Ordering) `
            -OwnerModId ([string]$dep.OwnerModId))) | Out-Null
    }

    $rawProvided = New-Object System.Collections.Generic.List[string]
    foreach ($mod in @($parsed.Mods)) {
      if ($null -eq $mod) { continue }
      $rawModId = [string]$mod.ModId
      if ([string]::IsNullOrWhiteSpace($rawModId)) { continue }
      $rawProvided.Add($rawModId.Trim()) | Out-Null
    }
    $jarProvidedIds = @($rawProvided.ToArray() | Sort-Object -Unique)
    $recordProvidedIds = if ($jarProvidedIds.Count -gt 0) { $jarProvidedIds } else { @($fallbackModId) }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($mod in @($parsed.Mods)) {
      if ($null -eq $mod) { continue }
      $modId = [string]$mod.ModId
      if ([string]::IsNullOrWhiteSpace($modId)) { $modId = $fallbackModId }
      $displayName = [string]$mod.DisplayName
      if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $modId }
      $version = [string]$mod.Version
      if ([string]::IsNullOrWhiteSpace($version)) { $version = "Unknown" }

      $recordDeps = New-Object System.Collections.Generic.List[object]
      foreach ($dep in @($dependencyRecords.ToArray())) {
        if ($null -eq $dep) { continue }
        $owner = [string]$dep.OwnerModId
        $matchesOwner = $false
        if (-not [string]::IsNullOrWhiteSpace($owner)) {
          $matchesOwner = [string]::Equals($owner, $modId, [System.StringComparison]::OrdinalIgnoreCase)
        } elseif ([string]::Equals($modId, $fallbackModId, [System.StringComparison]::OrdinalIgnoreCase)) {
          $matchesOwner = $true
        }
        if ($matchesOwner) {
          $recordDeps.Add($dep) | Out-Null
        }
      }

      $records.Add([pscustomobject]@{
          ModId        = $modId
          DisplayName  = $displayName
          Version      = $version
          ProvidedIds  = @($recordProvidedIds)
          Dependencies = @($recordDeps.ToArray())
          Loader       = $loaderName
        }) | Out-Null
    }

    return [pscustomobject]@{
      Loader            = $loaderName
      Records           = @($records.ToArray())
      DependencyRecords = @($dependencyRecords.ToArray())
      JarProvidedIds    = @($jarProvidedIds)
    }
  }

  $mcmodText = Get-McccJarEntryText -Zip $Zip -EntryPath "mcmod.info"
  if ($mcmodText) {
    $records = @(ConvertFrom-McccMcmodInfo -McmodInfoText $mcmodText -FallbackModId $fallbackModId)
    if ($records.Count -eq 0) { return $null }

    $provided = New-Object System.Collections.Generic.List[string]
    $deps = New-Object System.Collections.Generic.List[object]
    foreach ($record in $records) {
      foreach ($providedId in @($record.ProvidedIds)) {
        $value = [string]$providedId
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $provided.Add($value.Trim()) | Out-Null
      }
      foreach ($dep in @($record.Dependencies)) {
        if ($null -eq $dep) { continue }
        $deps.Add($dep) | Out-Null
      }
    }

    return [pscustomobject]@{
      Loader            = "Legacy"
      Records           = @($records)
      DependencyRecords = @($deps.ToArray())
      JarProvidedIds    = @($provided.ToArray() | Sort-Object -Unique)
    }
  }

  return $null
}

function Get-McccJarMetadata {
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarPath,
    [Parameter(Mandatory = $false)]
    [bool]$ThrowOnParseError = $false
  )

  if ([string]::IsNullOrWhiteSpace($JarPath)) { return $null }
  if (-not (Test-Path -LiteralPath $JarPath)) { return $null }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = $null
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    return Get-McccJarMetadataFromZipArchive -Zip $zip -JarPath $JarPath -ThrowOnParseError $ThrowOnParseError
  } finally {
    if ($null -ne $zip) { $zip.Dispose() }
  }
}
