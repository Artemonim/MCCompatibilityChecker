# * Shared runtime bootstrap helpers for MCCompatibilityChecker entry scripts.

function Resolve-McccBootstrapStartDir {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$StartDir = $PSScriptRoot
  )

  $resolvedStartDir = $StartDir
  if ([string]::IsNullOrWhiteSpace($resolvedStartDir)) {
    $resolvedStartDir = (Get-Location).Path
  }

  try {
    return (Resolve-Path -LiteralPath $resolvedStartDir -ErrorAction Stop).Path
  }
  catch {
    return [string]$resolvedStartDir
  }
}

function Resolve-McccScriptsDir {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [string]$StartDir
  )

  $resolvedStartDir = Resolve-McccBootstrapStartDir -StartDir $StartDir
  $candidateScriptsDirs = @(
    $resolvedStartDir,
    (Join-Path -Path $resolvedStartDir -ChildPath "..\scripts")
  )

  foreach ($candidate in $candidateScriptsDirs) {
    $sharedConfigPath = Join-Path -Path $candidate -ChildPath "Shared-Config.ps1"
    if (-not (Test-Path -LiteralPath $sharedConfigPath)) { continue }
    return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
  }

  return [System.IO.Path]::GetFullPath((Join-Path -Path $resolvedStartDir -ChildPath "..\scripts"))
}

function Get-McccSharedScriptPath {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [string]$StartDir,
    [Parameter(Mandatory = $true)]
    [string]$RelativePath
  )

  $scriptsDir = Resolve-McccScriptsDir -StartDir $StartDir
  $normalizedRelativePath = [string]$RelativePath
  if ([string]::IsNullOrWhiteSpace($normalizedRelativePath)) {
    return $scriptsDir
  }

  $normalizedRelativePath = $normalizedRelativePath.TrimStart("\", "/")
  return (Join-Path -Path $scriptsDir -ChildPath $normalizedRelativePath)
}

function Import-McccSharedScript {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [string]$StartDir,
    [Parameter(Mandatory = $true)]
    [string]$RelativePath,
    [Parameter(Mandatory = $false)]
    [string]$NotFoundMessage = "Shared helper not found: {0}",
    [Parameter(Mandatory = $false)]
    [switch]$Optional
  )

  $scriptPath = Get-McccSharedScriptPath -StartDir $StartDir -RelativePath $RelativePath
  if (-not (Test-Path -LiteralPath $scriptPath)) {
    if ($Optional) { return $null }
    throw ($NotFoundMessage -f $scriptPath)
  }

  . $scriptPath
  return (Resolve-Path -LiteralPath $scriptPath -ErrorAction Stop).Path
}

function Get-McccBootstrapProjectRoot {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $true)]
    [string]$StartDir,
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object]$ProjectConfig = $null
  )

  if ($null -ne $ProjectConfig -and -not [string]::IsNullOrWhiteSpace([string]$ProjectConfig.Root)) {
    return [string]$ProjectConfig.Root
  }

  $resolvedStartDir = Resolve-McccBootstrapStartDir -StartDir $StartDir
  if (Get-Command -Name Import-ProjectConfig -ErrorAction SilentlyContinue) {
    try {
      $resolvedConfig = Import-ProjectConfig -StartDir $resolvedStartDir
      if ($null -ne $resolvedConfig -and -not [string]::IsNullOrWhiteSpace([string]$resolvedConfig.Root)) {
        return [string]$resolvedConfig.Root
      }
    }
    catch {
      Write-Verbose ("Failed to resolve project config root: {0}" -f $_.Exception.Message)
    }
  }

  $scriptsDir = Resolve-McccScriptsDir -StartDir $resolvedStartDir
  $parentDir = Join-Path -Path $scriptsDir -ChildPath ".."
  try {
    return (Resolve-Path -LiteralPath $parentDir -ErrorAction Stop).Path
  }
  catch {
    return $resolvedStartDir
  }
}

function Initialize-McccRuntimeBootstrap {
  [CmdletBinding()]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$StartDir = $PSScriptRoot,
    [Parameter(Mandatory = $false)]
    [switch]$LoadConfig,
    [Parameter(Mandatory = $false)]
    [switch]$InitializeLocalization,
    [Parameter(Mandatory = $false)]
    [switch]$EnableConsoleLocalization,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$Language = "",
    [Parameter(Mandatory = $false)]
    [string]$ConfigNotFoundMessage = "Shared config helpers not found: {0}",
    [Parameter(Mandatory = $false)]
    [string]$LocalizationNotFoundMessage = "Shared localization helpers not found: {0}"
  )

  $resolvedStartDir = Resolve-McccBootstrapStartDir -StartDir $StartDir
  $scriptsDir = Resolve-McccScriptsDir -StartDir $resolvedStartDir
  $loadedPaths = @{}

  if ($LoadConfig) {
    $loadedPaths["Config"] = . Import-McccSharedScript `
      -StartDir $resolvedStartDir `
      -RelativePath "Shared-Config.ps1" `
      -NotFoundMessage $ConfigNotFoundMessage
  }

  if ($InitializeLocalization -or $EnableConsoleLocalization) {
    $loadedPaths["Localization"] = . Import-McccSharedScript `
      -StartDir $resolvedStartDir `
      -RelativePath "Shared-Localization.ps1" `
      -NotFoundMessage $LocalizationNotFoundMessage
    Initialize-McccLocalization -StartDir $resolvedStartDir -Language $Language | Out-Null
    if ($EnableConsoleLocalization) {
      Enable-McccConsoleLocalization
    }
  }

  $projectConfig = $null
  if (Get-Command -Name Import-ProjectConfig -ErrorAction SilentlyContinue) {
    try {
      $projectConfig = Import-ProjectConfig -StartDir $resolvedStartDir
    }
    catch {
      Write-Verbose ("Failed to load project config during bootstrap: {0}" -f $_.Exception.Message)
    }
  }

  $projectRoot = Get-McccBootstrapProjectRoot -StartDir $resolvedStartDir -ProjectConfig $projectConfig

  return [pscustomobject]@{
    StartDir = $resolvedStartDir
    ScriptsDir = $scriptsDir
    ProjectRoot = $projectRoot
    ProjectConfig = $projectConfig
    LoadedPaths = [pscustomobject]$loadedPaths
  }
}
