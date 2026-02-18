function Get-McccJarFiles {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$RootPaths,
    [Parameter(Mandatory = $false)]
    [switch]$Recurse,
    [Parameter(Mandatory = $false)]
    [ValidateSet("FullName", "Name", "LastWriteTime", "None")]
    [string]$SortBy = "FullName",
    [Parameter(Mandatory = $false)]
    [bool]$Descending = $false,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$IncludePatterns = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$ExcludePatterns = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [string[]]$ExcludeDirectoryNames = @(),
    [Parameter(Mandatory = $false)]
    [ValidateSet("Stop", "Continue", "SilentlyContinue", "Ignore")]
    [string]$EnumerationErrorAction = "SilentlyContinue"
  )

  if (-not $RootPaths -or $RootPaths.Count -eq 0) { return @() }

  $normalizedIncludePatterns = @($IncludePatterns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  $normalizedExcludePatterns = @($ExcludePatterns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  $excludeDirectorySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($directoryName in @($ExcludeDirectoryNames)) {
    $name = [string]$directoryName
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $null = $excludeDirectorySet.Add($name.Trim())
  }

  $jarFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
  $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($rootPath in @($RootPaths)) {
    $scanPath = [string]$rootPath
    if ([string]::IsNullOrWhiteSpace($scanPath)) { continue }

    $enumerationParams = @{
      LiteralPath = $scanPath
      Filter = "*.jar"
      File = $true
      ErrorAction = $EnumerationErrorAction
    }
    if ($Recurse) {
      $enumerationParams["Recurse"] = $true
    }

    foreach ($jar in @(Get-ChildItem @enumerationParams)) {
      if ($null -eq $jar) { continue }
      $jarPath = [string]$jar.FullName
      if ([string]::IsNullOrWhiteSpace($jarPath)) { continue }
      $jarName = [string]$jar.Name

      if ($excludeDirectorySet.Count -gt 0) {
        $dirPath = [string]$jar.DirectoryName
        if (-not [string]::IsNullOrWhiteSpace($dirPath)) {
          $segments = @($dirPath -split "[\\/]+" | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
          $skipByDirectory = $false
          foreach ($segment in $segments) {
            if ($excludeDirectorySet.Contains([string]$segment)) {
              $skipByDirectory = $true
              break
            }
          }
          if ($skipByDirectory) { continue }
        }
      }

      if ($normalizedIncludePatterns.Count -gt 0) {
        $matchesInclude = $false
        foreach ($pattern in $normalizedIncludePatterns) {
          if ($jarPath -like $pattern -or $jarName -like $pattern) {
            $matchesInclude = $true
            break
          }
        }
        if (-not $matchesInclude) { continue }
      }

      if ($normalizedExcludePatterns.Count -gt 0) {
        $matchesExclude = $false
        foreach ($pattern in $normalizedExcludePatterns) {
          if ($jarPath -like $pattern -or $jarName -like $pattern) {
            $matchesExclude = $true
            break
          }
        }
        if ($matchesExclude) { continue }
      }

      if ($seenPaths.Add($jarPath)) {
        $jarFiles.Add($jar) | Out-Null
      }
    }
  }

  if ($jarFiles.Count -eq 0) { return @() }

  if ($SortBy -eq "None") {
    return @($jarFiles.ToArray())
  }

  if ($SortBy -eq "Name") {
    if ($Descending) {
      return @($jarFiles | Sort-Object -Property @{ Expression = { $_.Name }; Descending = $true }, @{ Expression = { $_.FullName }; Descending = $false })
    }
    return @($jarFiles | Sort-Object -Property @{ Expression = { $_.Name }; Descending = $false }, @{ Expression = { $_.FullName }; Descending = $false })
  }

  if ($SortBy -eq "LastWriteTime") {
    if ($Descending) {
      return @($jarFiles | Sort-Object -Property @{ Expression = { $_.LastWriteTime }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false }, @{ Expression = { $_.FullName }; Descending = $false })
    }
    return @($jarFiles | Sort-Object -Property @{ Expression = { $_.LastWriteTime }; Descending = $false }, @{ Expression = { $_.Name }; Descending = $false }, @{ Expression = { $_.FullName }; Descending = $false })
  }

  if ($Descending) {
    return @($jarFiles | Sort-Object -Property @{ Expression = { $_.FullName }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false })
  }
  return @($jarFiles | Sort-Object -Property @{ Expression = { $_.FullName }; Descending = $false }, @{ Expression = { $_.Name }; Descending = $false })
}

function New-McccJarNamePathIndex {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$JarFilesOrPaths,
    [Parameter(Mandatory = $false)]
    [bool]$PreferLast = $true
  )

  $index = @{}
  foreach ($entry in @($JarFilesOrPaths)) {
    if ($null -eq $entry) { continue }

    $jarPath = ""
    $jarName = ""
    if ($entry -is [System.IO.FileInfo]) {
      $jarPath = [string]$entry.FullName
      $jarName = [string]$entry.Name
    } else {
      $jarPath = [string]$entry
      if ([string]::IsNullOrWhiteSpace($jarPath)) { continue }
      $jarName = [System.IO.Path]::GetFileName($jarPath)
    }

    if ([string]::IsNullOrWhiteSpace($jarPath) -or [string]::IsNullOrWhiteSpace($jarName)) { continue }
    $key = $jarName.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($key)) { continue }

    if ($PreferLast -or (-not $index.ContainsKey($key))) {
      $index[$key] = $jarPath
    }
  }

  return $index
}

function New-McccModIdJarPathIndex {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Items,
    [Parameter(Mandatory = $true)]
    [scriptblock]$GetJarPath,
    [Parameter(Mandatory = $true)]
    [scriptblock]$GetModIds
  )

  $index = @{}
  $seenPathsByModId = @{}

  foreach ($item in @($Items)) {
    if ($null -eq $item) { continue }

    $jarPath = [string](& $GetJarPath $item)
    if ([string]::IsNullOrWhiteSpace($jarPath)) { continue }

    $rawModIds = & $GetModIds $item
    $modIds = @()
    if ($null -eq $rawModIds) {
      $modIds = @()
    } elseif ($rawModIds -is [System.Collections.IEnumerable] -and -not ($rawModIds -is [string])) {
      $modIds = @($rawModIds)
    } else {
      $modIds = @($rawModIds)
    }

    foreach ($modIdEntry in @($modIds)) {
      $modId = [string]$modIdEntry
      if ([string]::IsNullOrWhiteSpace($modId)) { continue }
      $modKey = $modId.Trim().ToLowerInvariant()
      if ([string]::IsNullOrWhiteSpace($modKey)) { continue }

      if (-not $index.ContainsKey($modKey)) {
        $index[$modKey] = New-Object System.Collections.Generic.List[string]
        $seenPathsByModId[$modKey] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
      }

      if ($seenPathsByModId[$modKey].Add($jarPath)) {
        $index[$modKey].Add($jarPath) | Out-Null
      }
    }
  }

  return $index
}

function Get-McccCachedJarMetadata {
  param(
    [Parameter(Mandatory = $true)]
    [string]$JarPath,
    [Parameter(Mandatory = $true)]
    [hashtable]$Cache,
    [Parameter(Mandatory = $true)]
    [scriptblock]$GetMetadata,
    [Parameter(Mandatory = $false)]
    [bool]$CacheNullValues = $true
  )

  if ([string]::IsNullOrWhiteSpace($JarPath)) { return $null }
  $cacheKey = [string]$JarPath

  if ($Cache.ContainsKey($cacheKey)) {
    return $Cache[$cacheKey]
  }

  $metadata = & $GetMetadata $cacheKey
  if ($CacheNullValues -or $null -ne $metadata) {
    $Cache[$cacheKey] = $metadata
  }
  return $metadata
}
