function Get-PreIsolateSelection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string[]]$PreIsolateJarNames = @(),
    [Parameter(Mandatory = $false)]
    [string]$PreviousBaselineEvidenceKey = "",
    [Parameter(Mandatory = $false)]
    [string]$CurrentBaselineEvidenceKey = ""
  )

  $result = [pscustomobject]@{
    JarNames         = @()
    EvidenceMismatch = $false
  }

  if (-not $PreIsolateJarNames -or $PreIsolateJarNames.Count -eq 0) { return $result }

  if (-not [string]::IsNullOrWhiteSpace($PreviousBaselineEvidenceKey) -and -not [string]::IsNullOrWhiteSpace($CurrentBaselineEvidenceKey)) {
    if (-not [string]::Equals($PreviousBaselineEvidenceKey, $CurrentBaselineEvidenceKey, [System.StringComparison]::OrdinalIgnoreCase)) {
      $result.EvidenceMismatch = $true
      return $result
    }
  }

  $preIsolateSet = @{}
  foreach ($name in $PreIsolateJarNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $key = $name.ToLowerInvariant()
    if (-not $preIsolateSet.ContainsKey($key)) {
      $preIsolateSet[$key] = $name
    }
  }
  $result.JarNames = @($preIsolateSet.Values)
  return $result
}

function Get-LayeringTierPlan {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [object[]]$Tier3Mods = @(),
    [Parameter(Mandatory = $false)]
    [object[]]$Tier2Mods = @(),
    [Parameter(Mandatory = $false)]
    [object[]]$Tier1Mods = @(),
    [Parameter(Mandatory = $false)]
    [string[]]$CulpritJarNames = @(),
    [Parameter(Mandatory = $false)]
    [hashtable]$MovedJarNameSet = $null
  )

  $culpritSet = @{}
  foreach ($name in $CulpritJarNames) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $culpritSet[$name.ToLowerInvariant()] = $true
  }

  $filteredTier3 = @($Tier3Mods | Where-Object {
      $jarName = [string]$_.Name
      $include = $null -eq $MovedJarNameSet -or $MovedJarNameSet.ContainsKey($jarName)
      -not $culpritSet.ContainsKey($jarName.ToLowerInvariant()) -and $include
    })
  $filteredTier2 = @($Tier2Mods | Where-Object {
      $jarName = [string]$_.Name
      $include = $null -eq $MovedJarNameSet -or $MovedJarNameSet.ContainsKey($jarName)
      -not $culpritSet.ContainsKey($jarName.ToLowerInvariant()) -and $include
    })
  $filteredTier1 = @($Tier1Mods | Where-Object {
      $jarName = [string]$_.Name
      $include = $null -eq $MovedJarNameSet -or $MovedJarNameSet.ContainsKey($jarName)
      -not $culpritSet.ContainsKey($jarName.ToLowerInvariant()) -and $include
    })

  return @(
    @{ Tier = 3; Mods = $filteredTier3 },
    @{ Tier = 2; Mods = $filteredTier2 },
    @{ Tier = 1; Mods = $filteredTier1 }
  )
}
