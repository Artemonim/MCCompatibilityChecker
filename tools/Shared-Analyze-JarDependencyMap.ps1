function New-McccJarDependencyMapDiagnosticRecord {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Warning", "Error", "Info")]
    [string]$Severity,
    [Parameter(Mandatory = $true)]
    [string]$Category,
    [Parameter(Mandatory = $false)]
    [string]$Code = "",
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Message,
    [Parameter(Mandatory = $false)]
    [hashtable]$Context = @{},
    [Parameter(Mandatory = $false)]
    [string]$ExceptionType = ""
  )

  return [pscustomobject]@{
    Severity      = $Severity
    Category      = $Category
    Code          = $Code
    Message       = $Message
    Context       = if ($null -eq $Context) { @{} } else { $Context }
    ExceptionType = $ExceptionType
  }
}

function New-McccJarDependencyMapWarningRecord {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Category,
    [Parameter(Mandatory = $false)]
    [string]$Code = "",
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Message,
    [Parameter(Mandatory = $false)]
    [hashtable]$Context = @{},
    [Parameter(Mandatory = $false)]
    [string]$ExceptionType = ""
  )

  return New-McccJarDependencyMapDiagnosticRecord `
    -Severity "Warning" `
    -Category $Category `
    -Code $Code `
    -Message $Message `
    -Context $Context `
    -ExceptionType $ExceptionType
}

function New-McccDependencyMapEdge {
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

  return [pscustomobject]@{
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

function Get-McccJarDependencyMapScanData {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScanPath,
    [Parameter(Mandatory = $true)]
    [bool]$Recurse
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem

  $jarFiles = @(Get-ChildItem -LiteralPath $ScanPath -Filter "*.jar" -Recurse:$Recurse -File)
  $modRecords = [System.Collections.Generic.List[object]]::new()
  $dependencyEdges = [System.Collections.Generic.List[object]]::new()
  $errorRecords = [System.Collections.Generic.List[object]]::new()
  $warningRecords = [System.Collections.Generic.List[object]]::new()
  $diagnostics = [System.Collections.Generic.List[object]]::new()

  if ($jarFiles.Count -eq 0) {
    return [pscustomobject]@{
      JarFiles         = @()
      ModRecords       = @()
      DependencyEdges  = @()
      ErrorRecords     = @()
      WarningRecords   = @()
      Diagnostics      = @()
    }
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
      $metadata = Get-McccJarMetadataFromZipArchive -Zip $zip -JarPath $jarFile.FullName -ThrowOnParseError $true
      if ($null -eq $metadata) {
        continue
      }

      $loaderName = [string]$metadata.Loader
      $records = @($metadata.Records)
      $dependencyRecords = @($metadata.DependencyRecords)
      $modNameById = @{}

      $forgeProvidedFallback = @()
      if ($loaderName -eq "Forge" -or $loaderName -eq "NeoForge") {
        $rawProvided = @($metadata.JarProvidedIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($rawProvided.Count -eq 0) {
          $forgeProvidedFallback = @([string]$jarFile.BaseName)
        } else {
          $forgeProvidedFallback = @($rawProvided | Sort-Object -Unique)
        }
      }

      foreach ($record in $records) {
        if ($null -eq $record) { continue }

        $modId = [string]$record.ModId
        if ([string]::IsNullOrWhiteSpace($modId)) {
          $modId = [string]$jarFile.BaseName
        }

        $modName = [string]$record.DisplayName
        if ([string]::IsNullOrWhiteSpace($modName)) {
          $modName = $modId
        }

        $version = [string]$record.Version
        if ([string]::IsNullOrWhiteSpace($version)) {
          $version = "Unknown"
        }

        $providedList = @()
        if ($loaderName -eq "Forge" -or $loaderName -eq "NeoForge") {
          $providedList = @($forgeProvidedFallback)
        } else {
          $providedList = @($record.ProvidedIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        }

        $modRecords.Add([pscustomobject]@{
            ModId          = $modId
            ModName        = $modName
            Version        = $version
            Loader         = $loaderName
            JarName        = $jarFile.Name
            JarPath        = $jarFile.FullName
            ProvidedModIds = $providedList
          }) | Out-Null

        if (-not [string]::IsNullOrWhiteSpace($modId)) {
          $modNameById[$modId.ToLowerInvariant()] = $modName
        }
      }

      foreach ($dep in $dependencyRecords) {
        if ($null -eq $dep) { continue }
        $dependencyId = [string]$dep.ModId
        if ([string]::IsNullOrWhiteSpace($dependencyId)) { continue }

        $fromModId = [string]$dep.OwnerModId
        if ([string]::IsNullOrWhiteSpace($fromModId)) {
          if ($records.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$records[0].ModId)) {
            $fromModId = [string]$records[0].ModId
          } else {
            $fromModId = [string]$jarFile.BaseName
          }
        }

        $fromModName = $fromModId
        if ($loaderName -eq "Fabric" -or $loaderName -eq "Quilt" -or $loaderName -eq "Legacy") {
          $fromKey = $fromModId.ToLowerInvariant()
          if ($modNameById.ContainsKey($fromKey)) {
            $fromModName = [string]$modNameById[$fromKey]
          }
        }

        $isRequired = $false
        if ($dep.PSObject.Properties.Name -contains "IsRequired" -and $null -ne $dep.IsRequired) {
          $isRequired = [bool]$dep.IsRequired
        } elseif ([string]$dep.Kind -eq "depends") {
          $isRequired = $true
        }

        $kind = [string]$dep.Kind
        if ([string]::IsNullOrWhiteSpace($kind) -and ($loaderName -eq "Forge" -or $loaderName -eq "NeoForge")) {
          $kind = "dependency"
        }

        $dependencyEdges.Add((New-McccDependencyMapEdge `
              -FromModId $fromModId `
              -FromModName $fromModName `
              -DependencyId $dependencyId `
              -VersionRange ([string]$dep.VersionRange) `
              -Kind $kind `
              -IsRequired $isRequired `
              -Side ([string]$dep.Side) `
              -Ordering ([string]$dep.Ordering) `
              -Loader $loaderName `
              -JarName $jarFile.Name `
              -JarPath $jarFile.FullName)) | Out-Null
      }
    } catch [System.IO.InvalidDataException] {
      $warningMessage = ("Invalid archive: {0}" -f $jarFile.FullName)
      $errorRecords.Add([pscustomobject]@{
          JarPath = $jarFile.FullName
          Error   = $_.Exception.Message
        }) | Out-Null
      $warningRecord = New-McccJarDependencyMapWarningRecord `
        -Category "jar_read" `
        -Code "INVALID_ARCHIVE" `
        -Message $warningMessage `
        -Context @{
        JarPath = $jarFile.FullName
        Operation = "read_jar_metadata"
      } `
        -ExceptionType $_.Exception.GetType().FullName
      $warningRecords.Add($warningRecord) | Out-Null
      $diagnostics.Add($warningRecord) | Out-Null
      Write-Warning $warningMessage
    } catch [System.UnauthorizedAccessException] {
      $warningMessage = ("Access denied: {0}" -f $jarFile.FullName)
      $errorRecords.Add([pscustomobject]@{
          JarPath = $jarFile.FullName
          Error   = $_.Exception.Message
        }) | Out-Null
      $warningRecord = New-McccJarDependencyMapWarningRecord `
        -Category "jar_read" `
        -Code "ACCESS_DENIED" `
        -Message $warningMessage `
        -Context @{
        JarPath = $jarFile.FullName
        Operation = "read_jar_metadata"
      } `
        -ExceptionType $_.Exception.GetType().FullName
      $warningRecords.Add($warningRecord) | Out-Null
      $diagnostics.Add($warningRecord) | Out-Null
      Write-Warning $warningMessage
    } catch [System.IO.IOException] {
      $warningMessage = ("IO error: {0}" -f $jarFile.FullName)
      $errorRecords.Add([pscustomobject]@{
          JarPath = $jarFile.FullName
          Error   = $_.Exception.Message
        }) | Out-Null
      $warningRecord = New-McccJarDependencyMapWarningRecord `
        -Category "jar_read" `
        -Code "IO_ERROR" `
        -Message $warningMessage `
        -Context @{
        JarPath = $jarFile.FullName
        Operation = "read_jar_metadata"
      } `
        -ExceptionType $_.Exception.GetType().FullName
      $warningRecords.Add($warningRecord) | Out-Null
      $diagnostics.Add($warningRecord) | Out-Null
      Write-Warning $warningMessage
    } catch {
      $warningMessage = ("Unhandled error: {0}" -f $jarFile.FullName)
      $errorRecords.Add([pscustomobject]@{
          JarPath = $jarFile.FullName
          Error   = $_.Exception.Message
        }) | Out-Null
      $warningRecord = New-McccJarDependencyMapWarningRecord `
        -Category "jar_read" `
        -Code "UNHANDLED_ERROR" `
        -Message $warningMessage `
        -Context @{
        JarPath = $jarFile.FullName
        Operation = "read_jar_metadata"
      } `
        -ExceptionType $_.Exception.GetType().FullName
      $warningRecords.Add($warningRecord) | Out-Null
      $diagnostics.Add($warningRecord) | Out-Null
      Write-Warning $warningMessage
    } finally {
      if ($zip) {
        $zip.Dispose()
      }
    }
  }

  Write-Progress -Activity "Scanning JAR files" -Completed

  return [pscustomobject]@{
    JarFiles         = @($jarFiles)
    ModRecords       = @($modRecords.ToArray())
    DependencyEdges  = @($dependencyEdges.ToArray())
    ErrorRecords     = @($errorRecords.ToArray())
    WarningRecords   = @($warningRecords.ToArray())
    Diagnostics      = @($diagnostics.ToArray())
  }
}

function Get-McccJarDependencyMapUsageData {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$ModRecords = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$DependencyEdges = @()
  )

  $modIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($mod in @($ModRecords)) {
    if ($null -eq $mod) { continue }
    if (-not [string]::IsNullOrWhiteSpace([string]$mod.ModId)) {
      $modIdSet.Add([string]$mod.ModId) | Out-Null
    }
  }

  $dependencyUsage = @(
    @($DependencyEdges) |
      Group-Object -Property DependencyId |
      ForEach-Object {
        $references = @($_.Group)
        $requiredCount = @($references | Where-Object { $_.IsRequired -eq $true }).Count
        $refMods = @($references | Select-Object -ExpandProperty FromModId -Unique)
        [pscustomobject]@{
          DependencyId    = $_.Name
          ReferenceCount  = $_.Count
          RequiredCount   = $requiredCount
          ReferencingMods = $refMods
          IsPresentAsMod  = $modIdSet.Contains([string]$_.Name)
        }
      }
  )

  $missingDependencies = @($dependencyUsage | Where-Object { $_.IsPresentAsMod -eq $false })
  return [pscustomobject]@{
    Usage               = $dependencyUsage
    MissingDependencies = $missingDependencies
  }
}

function New-McccJarDependencyMapReportData {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScanPath,
    [Parameter(Mandatory = $true)]
    [bool]$Recurse,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$JarFiles = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$ModRecords = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$DependencyEdges = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$DependencyUsage = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$MissingDependencies = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$WarningRecords = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$ErrorRecords = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$Diagnostics = @()
  )

  return [pscustomobject]@{
    Scan                = [pscustomobject]@{
      Path            = $ScanPath
      Recursive       = $Recurse
      JarCount        = @($JarFiles).Count
      ModCount        = @($ModRecords).Count
      DependencyCount = @($DependencyEdges).Count
      GeneratedAt     = (Get-Date).ToString("s")
    }
    Mods                = @($ModRecords)
    Dependencies        = @($DependencyEdges)
    Usage               = @($DependencyUsage)
    MissingDependencies = @($MissingDependencies)
    Warnings            = @($WarningRecords)
    Errors              = @($ErrorRecords)
    Diagnostics         = @($Diagnostics)
  }
}

function Write-McccJarDependencyMapConsoleReport {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$JarFiles = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$ModRecords = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$DependencyEdges = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$ErrorRecords = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$DependencyUsage = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$MissingDependencies = @(),
    [Parameter(Mandatory = $false)]
    [int]$TopDependencies = 30
  )

  Write-Host ("`n[+] JARs scanned: {0}" -f @($JarFiles).Count) -ForegroundColor Green
  Write-Host ("[+] Mods found: {0}" -f @($ModRecords).Count) -ForegroundColor Green
  Write-Host ("[+] Dependency edges: {0}" -f @($DependencyEdges).Count) -ForegroundColor Green
  Write-Host ("[+] JAR parse/read errors: {0}" -f @($ErrorRecords).Count) -ForegroundColor Green

  if (@($DependencyUsage).Count -gt 0) {
    Write-Host ("`n[+] Top dependencies (by reference count):") -ForegroundColor Cyan
    @($DependencyUsage) |
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

  if (@($MissingDependencies).Count -gt 0) {
    $requiredMissingDependencies = @(@($MissingDependencies) | Where-Object { $_.RequiredCount -gt 0 })
    Write-Host ("`n[!] Dependency IDs without provider mods in scan path: {0}" -f @($MissingDependencies).Count) -ForegroundColor Yellow
    Write-Host ("[!] Of them required by at least one mod: {0}" -f $requiredMissingDependencies.Count) -ForegroundColor Yellow
  }
}

function Export-McccJarDependencyMapReports {
  param(
    [Parameter(Mandatory = $true)]
    [string]$OutDir,
    [Parameter(Mandatory = $true)]
    [pscustomobject]$DependencyMap,
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$DependencyEdges = @(),
    [Parameter(Mandatory = $false)]
    [AllowEmptyCollection()]
    [object[]]$DependencyUsage = @()
  )

  $jsonPath = Join-Path $OutDir "jar-dependency-map.json"
  $csvPath = Join-Path $OutDir "jar-dependency-edges.csv"
  $summaryPath = Join-Path $OutDir "jar-dependency-summary.json"

  $DependencyMap | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
  @($DependencyEdges) | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
  @($DependencyUsage) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

  return [pscustomobject]@{
    JsonPath    = $jsonPath
    CsvPath     = $csvPath
    SummaryPath = $summaryPath
  }
}
