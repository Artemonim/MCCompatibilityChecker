# * Shared localization helpers for MCCompatibilityChecker console output.

$script:McccLocalizationState = @{
  Initialized = $false
  Locale = "en"
  TemplateRules = @()
  Substrings = @{}
  SubstringKeys = @()
  TagValues = @{}
  TagKeys = @()
}

$script:McccConsoleLocalizationEnabled = $false

function ConvertTo-McccLocaleTag {
  param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$Value = ""
  )

  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }

  $trimmed = $Value.Trim()
  if ([string]::IsNullOrWhiteSpace($trimmed)) { return "" }

  $normalized = $trimmed -replace "_", "-"
  $parts = @($normalized -split "-")
  if ($parts.Count -eq 0) { return "" }

  $lang = $parts[0].ToLowerInvariant()
  if ($parts.Count -eq 1) {
    return $lang
  }

  $region = $parts[1]
  if ($region.Length -eq 2) {
    $region = $region.ToUpperInvariant()
  }
  else {
    $region = $region
  }

  return ("{0}-{1}" -f $lang, $region)
}

function ConvertTo-McccNormalizedNewLine {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  return (($Value -replace "`r`n", "`n") -replace "`r", "`n")
}

function Restore-McccOriginalLineEnding {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Original,
    [Parameter(Mandatory = $true)]
    [string]$Localized
  )

  if ($Original -like "*`r`n*") {
    return ($Localized -replace "`n", "`r`n")
  }

  return $Localized
}

function Get-McccProjectRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StartDir
  )

  $dir = $StartDir
  while (-not [string]::IsNullOrWhiteSpace($dir)) {
    $agentsPath = Join-Path -Path $dir -ChildPath "AGENTS.md"
    $scriptsPath = Join-Path -Path $dir -ChildPath "scripts"
    if ((Test-Path -LiteralPath $agentsPath) -and (Test-Path -LiteralPath $scriptsPath)) {
      return (Resolve-Path -LiteralPath $dir).Path
    }

    $parent = Split-Path -Path $dir -Parent
    if ($parent -eq $dir) { break }
    $dir = $parent
  }

  return $null
}

function Get-McccLanguageFromConfig {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath
  )

  $configured = ""
  foreach ($name in @("config.ini", "config.local.ini")) {
    $path = Join-Path -Path $RootPath -ChildPath $name
    if (-not (Test-Path -LiteralPath $path)) { continue }

    $section = ""
    foreach ($rawLine in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
      if ($null -eq $rawLine) { continue }
      $line = [string]$rawLine
      if ([string]::IsNullOrWhiteSpace($line)) { continue }

      $trimmed = $line.Trim()
      if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
      if ($trimmed.StartsWith(";") -or $trimmed.StartsWith("#")) { continue }

      if ($trimmed -match '^\[(?<name>[^\]]+)\]\s*$') {
        $section = [string]$Matches["name"]
        continue
      }

      if ($section -ne "Localization") { continue }
      $eqIndex = $trimmed.IndexOf("=")
      if ($eqIndex -lt 1) { continue }

      $key = $trimmed.Substring(0, $eqIndex).Trim()
      $value = $trimmed.Substring($eqIndex + 1).Trim()
      if ([string]::IsNullOrWhiteSpace($value)) { continue }
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        if ($value.Length -ge 2) {
          $value = $value.Substring(1, $value.Length - 2)
        }
      }

      if (($key -ieq "Language") -or ($key -ieq "Locale")) {
        $configured = $value
      }
    }
  }

  return $configured
}

function Get-McccLanguageFromOperatingSystem {
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $candidates = New-Object System.Collections.Generic.List[string]

  try {
    $uiCulture = [System.Globalization.CultureInfo]::CurrentUICulture
    if ($null -ne $uiCulture) {
      if (-not [string]::IsNullOrWhiteSpace([string]$uiCulture.Name)) {
        $candidates.Add([string]$uiCulture.Name) | Out-Null
      }
      if (-not [string]::IsNullOrWhiteSpace([string]$uiCulture.TwoLetterISOLanguageName)) {
        $candidates.Add([string]$uiCulture.TwoLetterISOLanguageName) | Out-Null
      }
    }
  }
  catch {
    Write-Verbose ("Failed to read OS UI culture: {0}" -f $_.Exception.Message)
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$PSUICulture)) {
    $candidates.Add([string]$PSUICulture) | Out-Null
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$PSCulture)) {
    $candidates.Add([string]$PSCulture) | Out-Null
  }

  foreach ($item in ($candidates.ToArray() | Select-Object -Unique)) {
    $normalized = ConvertTo-McccLocaleTag -Value ([string]$item)
    if (-not [string]::IsNullOrWhiteSpace($normalized)) {
      return $normalized
    }
  }

  return ""
}

function ConvertTo-McccStringMap {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object]$Value = $null
  )

  $map = @{}
  if ($null -eq $Value) { return $map }

  if ($Value -is [hashtable]) {
    foreach ($key in $Value.Keys) {
      $k = [string]$key
      $v = [string]$Value[$key]
      $map[$k] = $v
    }
    return $map
  }

  if ($null -ne $Value.PSObject -and $null -ne $Value.PSObject.Properties) {
    foreach ($prop in $Value.PSObject.Properties) {
      if ($null -eq $prop) { continue }
      $k = [string]$prop.Name
      $v = [string]$prop.Value
      $map[$k] = $v
    }
  }

  return $map
}

function Get-McccLocaleDataPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Locale,
    [Parameter(Mandatory = $true)]
    [string]$RootPath
  )

  $localeDir = Join-Path -Path $RootPath -ChildPath "scripts\locales"
  if (-not (Test-Path -LiteralPath $localeDir)) { return $null }

  $normalized = ConvertTo-McccLocaleTag -Value $Locale
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    $normalized = "en"
  }

  $candidates = New-Object System.Collections.Generic.List[string]
  $candidates.Add($normalized) | Out-Null

  if ($normalized -match "-") {
    $candidates.Add(($normalized -replace "-", "_")) | Out-Null
    $parts = @($normalized -split "-")
    if ($parts.Count -gt 0) {
      $candidates.Add($parts[0]) | Out-Null
    }
  }

  if ($normalized -match "_") {
    $candidates.Add(($normalized -replace "_", "-")) | Out-Null
    $parts = @($normalized -split "_")
    if ($parts.Count -gt 0) {
      $candidates.Add($parts[0]) | Out-Null
    }
  }

  foreach ($candidate in ($candidates.ToArray() | Sort-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $path = Join-Path -Path $localeDir -ChildPath ("{0}.psd1" -f $candidate)
    if (Test-Path -LiteralPath $path) {
      return (Resolve-Path -LiteralPath $path).Path
    }
  }

  return $null
}

function Import-McccLocaleData {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Locale,
    [Parameter(Mandatory = $true)]
    [string]$RootPath
  )

  $path = Get-McccLocaleDataPath -Locale $Locale -RootPath $RootPath
  if ($null -eq $path -and ((ConvertTo-McccLocaleTag -Value $Locale) -ne "en")) {
    $path = Get-McccLocaleDataPath -Locale "en" -RootPath $RootPath
  }

  if ($null -eq $path) {
    return @{
      Locale = "en"
      Templates = @{}
      Substrings = @{}
    }
  }

  $data = Import-PowerShellDataFile -LiteralPath $path
  if ($null -eq $data) {
    return @{
      Locale = "en"
      Templates = @{}
      Substrings = @{}
    }
  }

  $localeValue = "en"
  if ($data.ContainsKey("Locale") -and (-not [string]::IsNullOrWhiteSpace([string]$data.Locale))) {
    $localeValue = [string]$data.Locale
  }
  else {
    $localeValue = [System.IO.Path]::GetFileNameWithoutExtension($path)
  }

  return @{
    Locale = $localeValue
    Templates = (ConvertTo-McccStringMap -Value $data.Templates)
    Substrings = (ConvertTo-McccStringMap -Value $data.Substrings)
  }
}

function New-McccTemplateRule {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceTemplate,
    [Parameter(Mandatory = $true)]
    [string]$TargetTemplate
  )

  $sourceNormalized = ConvertTo-McccNormalizedNewLine -Value $SourceTemplate
  $targetNormalized = ConvertTo-McccNormalizedNewLine -Value $TargetTemplate

  $escaped = [regex]::Escape($sourceNormalized)
  $indexMap = @{}
  $placeholderPattern = '\\\{(\d+)\}'
  $pattern = [regex]::Replace(
    $escaped,
    $placeholderPattern,
    [System.Text.RegularExpressions.MatchEvaluator]{
      param([System.Text.RegularExpressions.Match]$match)
      $idx = [int]$match.Groups[1].Value
      $indexMap[$idx] = $true
      return ("(?<p{0}>.+?)" -f $idx)
    }
  )

  $indexes = @($indexMap.Keys | ForEach-Object { [int]$_ } | Sort-Object)
  $maxIndex = -1
  if ($indexes.Count -gt 0) {
    $maxIndex = ($indexes | Measure-Object -Maximum).Maximum
  }

  return [pscustomobject]@{
    SourceTemplate = $sourceNormalized
    TargetTemplate = $targetNormalized
    Regex = [regex]::new(("^{0}$" -f $pattern), [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    Indexes = $indexes
    MaxIndex = [int]$maxIndex
  }
}

function Initialize-McccLocalization {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string]$StartDir = $PSScriptRoot,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$Language = ""
  )

  if ([string]::IsNullOrWhiteSpace($StartDir)) {
    $StartDir = (Get-Location).Path
  }

  $root = Get-McccProjectRoot -StartDir $StartDir
  if ([string]::IsNullOrWhiteSpace($root)) {
    $root = $StartDir
  }

  $requested = $Language
  if ([string]::IsNullOrWhiteSpace($requested)) {
    $requested = $env:MCCC_LANG
  }
  if ([string]::IsNullOrWhiteSpace($requested)) {
    $requested = Get-McccLanguageFromConfig -RootPath $root
  }
  if ([string]::IsNullOrWhiteSpace($requested)) {
    $requested = Get-McccLanguageFromOperatingSystem
  }
  if ([string]::IsNullOrWhiteSpace($requested)) {
    $requested = "en"
  }

  $localeData = Import-McccLocaleData -Locale $requested -RootPath $root
  $effectiveLocale = ConvertTo-McccLocaleTag -Value $localeData.Locale
  if ([string]::IsNullOrWhiteSpace($effectiveLocale)) {
    $effectiveLocale = ConvertTo-McccLocaleTag -Value $requested
  }
  if ([string]::IsNullOrWhiteSpace($effectiveLocale)) {
    $effectiveLocale = "en"
  }

  $rules = New-Object System.Collections.Generic.List[object]
  foreach ($source in ($localeData.Templates.Keys | Sort-Object { $_.Length } -Descending)) {
    if ([string]::IsNullOrWhiteSpace([string]$source)) { continue }
    $target = [string]$localeData.Templates[$source]
    if ([string]::IsNullOrEmpty($target)) { continue }
    $rules.Add((New-McccTemplateRule -SourceTemplate ([string]$source) -TargetTemplate $target)) | Out-Null
  }

  $substrings = @{}
  foreach ($key in $localeData.Substrings.Keys) {
    if ([string]::IsNullOrWhiteSpace([string]$key)) { continue }
    $value = [string]$localeData.Substrings[$key]
    if ([string]::IsNullOrEmpty($value)) { continue }
    $substrings[[string]$key] = $value
  }
  $substringKeys = @($substrings.Keys | Sort-Object { $_.Length } -Descending)

  $script:McccLocalizationState = @{
    Initialized = $true
    Locale = $effectiveLocale
    TemplateRules = @($rules.ToArray())
    Substrings = $substrings
    SubstringKeys = $substringKeys
    TagValues = @{}
    TagKeys = @()
  }

  return [pscustomobject]@{
    Locale = $effectiveLocale
    TemplateRules = $script:McccLocalizationState.TemplateRules.Count
    Substrings = $script:McccLocalizationState.Substrings.Count
  }
}

function Set-McccLocalizationTagValue {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$TagMap,
    [Parameter(Mandatory = $false)]
    [switch]$Reset
  )

  if (-not $script:McccLocalizationState.Initialized) {
    return
  }

  if ($Reset) {
    $script:McccLocalizationState.TagValues = @{}
  }

  foreach ($key in $TagMap.Keys) {
    $tag = [string]$key
    if ([string]::IsNullOrWhiteSpace($tag)) { continue }
    $script:McccLocalizationState.TagValues[$tag] = [string]$TagMap[$key]
  }

  $script:McccLocalizationState.TagKeys = @($script:McccLocalizationState.TagValues.Keys | Sort-Object { $_.Length } -Descending)
}

function Resolve-McccLocalizationTag {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string]$Message = $null
  )

  if ($null -eq $Message) { return $null }
  if ([string]::IsNullOrEmpty($Message)) { return $Message }
  if (-not $script:McccLocalizationState.Initialized) { return $Message }
  if ($script:McccLocalizationState.TagKeys.Count -eq 0) { return $Message }

  $expanded = $Message
  foreach ($tag in $script:McccLocalizationState.TagKeys) {
    $expanded = $expanded.Replace([string]$tag, [string]$script:McccLocalizationState.TagValues[$tag])
  }

  return $expanded
}

function Resolve-McccLocalizedMessage {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [string]$Message = $null
  )

  if ($null -eq $Message) { return $null }
  if ([string]::IsNullOrEmpty($Message)) { return $Message }
  if (-not $script:McccLocalizationState.Initialized) { return $Message }

  $normalized = ConvertTo-McccNormalizedNewLine -Value $Message

  foreach ($rule in $script:McccLocalizationState.TemplateRules) {
    $match = $rule.Regex.Match($normalized)
    if (-not $match.Success) { continue }

    $localized = $rule.TargetTemplate
    if ($rule.MaxIndex -ge 0) {
        $formatArgs = New-Object object[] ($rule.MaxIndex + 1)
        foreach ($idx in $rule.Indexes) {
          $formatArgs[$idx] = $match.Groups[("p{0}" -f $idx)].Value
        }

        try {
          $localized = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $rule.TargetTemplate, $formatArgs)
      }
      catch {
        $localized = $rule.TargetTemplate
      }
    }

    return (Resolve-McccLocalizationTag -Message (Restore-McccOriginalLineEnding -Original $Message -Localized $localized))
  }

  if ($script:McccLocalizationState.SubstringKeys.Count -gt 0) {
    $localizedByParts = $normalized
    foreach ($key in $script:McccLocalizationState.SubstringKeys) {
      $replacement = [string]$script:McccLocalizationState.Substrings[$key]
      $pattern = [regex]::Escape([string]$key)
      if ([string]$key -match '^[\p{L}\p{Nd}]') {
        $pattern = ("(?<![\p{L}\p{Nd}_-])" + $pattern)
      }
      if ([string]$key -match '[\p{L}\p{Nd}]$') {
        $pattern = ($pattern + "(?![\p{L}\p{Nd}_-])")
      }

      $localizedByParts = [regex]::Replace(
        $localizedByParts,
        $pattern,
        [System.Text.RegularExpressions.MatchEvaluator]{
          return $replacement
        },
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
      )
    }

    if ($localizedByParts -ne $normalized) {
      return (Resolve-McccLocalizationTag -Message (Restore-McccOriginalLineEnding -Original $Message -Localized $localizedByParts))
    }
  }

  return (Resolve-McccLocalizationTag -Message $Message)
}

function ConvertTo-McccLocalizedObjectList {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object[]]$Object = @()
  )

  if ($null -eq $Object) { return @() }

  $translated = New-Object System.Collections.Generic.List[object]
  foreach ($item in $Object) {
    if ($item -is [string]) {
      $translated.Add((Resolve-McccLocalizedMessage -Message ([string]$item))) | Out-Null
      continue
    }

    $translated.Add($item) | Out-Null
  }

  return ,@($translated.ToArray())
}

function Write-McccHost {
  [CmdletBinding(DefaultParameterSetName = "NoSeparator")]
  param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [AllowNull()]
    [object[]]$Object,
    [switch]$NoNewline,
    [object]$Separator,
    [ConsoleColor]$ForegroundColor,
    [ConsoleColor]$BackgroundColor
  )

  $params = @{}
  $params.Object = (ConvertTo-McccLocalizedObjectList -Object $Object)
  if ($PSBoundParameters.ContainsKey("NoNewline")) { $params.NoNewline = $NoNewline }
  if ($PSBoundParameters.ContainsKey("Separator")) { $params.Separator = $Separator }
  if ($PSBoundParameters.ContainsKey("ForegroundColor")) { $params.ForegroundColor = $ForegroundColor }
  if ($PSBoundParameters.ContainsKey("BackgroundColor")) { $params.BackgroundColor = $BackgroundColor }

  Microsoft.PowerShell.Utility\Write-Host @params
}

function Write-McccWarning {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string]$Message
  )

  process {
    Microsoft.PowerShell.Utility\Write-Warning -Message (Resolve-McccLocalizedMessage -Message $Message)
  }
}

function Write-McccError {
  [CmdletBinding(DefaultParameterSetName = "Message")]
  param(
    [Parameter(ParameterSetName = "Message", Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string]$Message,
    [Parameter(ParameterSetName = "Exception", Mandatory = $true)]
    [System.Exception]$Exception,
    [Parameter(ParameterSetName = "ErrorRecord", Mandatory = $true)]
    [System.Management.Automation.ErrorRecord]$ErrorRecord,
    [System.Management.Automation.ErrorCategory]$Category,
    [string]$ErrorId,
    [object]$TargetObject,
    [string]$RecommendedAction,
    [string]$CategoryActivity,
    [string]$CategoryReason,
    [string]$CategoryTargetName,
    [string]$CategoryTargetType
  )

  process {
    $params = @{}
    switch ($PSCmdlet.ParameterSetName) {
      "Message" {
        $params.Message = (Resolve-McccLocalizedMessage -Message $Message)
      }
      "Exception" {
        $params.Exception = $Exception
      }
      "ErrorRecord" {
        $params.ErrorRecord = $ErrorRecord
      }
    }

    if ($PSBoundParameters.ContainsKey("Category")) { $params.Category = $Category }
    if ($PSBoundParameters.ContainsKey("ErrorId")) { $params.ErrorId = $ErrorId }
    if ($PSBoundParameters.ContainsKey("TargetObject")) { $params.TargetObject = $TargetObject }
    if ($PSBoundParameters.ContainsKey("RecommendedAction")) { $params.RecommendedAction = $RecommendedAction }
    if ($PSBoundParameters.ContainsKey("CategoryActivity")) { $params.CategoryActivity = $CategoryActivity }
    if ($PSBoundParameters.ContainsKey("CategoryReason")) { $params.CategoryReason = $CategoryReason }
    if ($PSBoundParameters.ContainsKey("CategoryTargetName")) { $params.CategoryTargetName = $CategoryTargetName }
    if ($PSBoundParameters.ContainsKey("CategoryTargetType")) { $params.CategoryTargetType = $CategoryTargetType }

    Microsoft.PowerShell.Utility\Write-Error @params
  }
}

function Read-McccHost {
  [CmdletBinding(DefaultParameterSetName = "Normal")]
  param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string]$Prompt,
    [Parameter(ParameterSetName = "Secure")]
    [switch]$AsSecureString
  )

  $localizedPrompt = Resolve-McccLocalizedMessage -Message $Prompt
  if ($PSBoundParameters.ContainsKey("AsSecureString")) {
    return (Microsoft.PowerShell.Utility\Read-Host -Prompt $localizedPrompt -AsSecureString)
  }

  return (Microsoft.PowerShell.Utility\Read-Host -Prompt $localizedPrompt)
}

function Enable-McccConsoleLocalization {
  if ($script:McccConsoleLocalizationEnabled) { return }
  $script:McccConsoleLocalizationEnabled = $true

  New-Item -Path Function:script:Write-Host -Value ${function:Write-McccHost} -Force | Out-Null
  New-Item -Path Function:script:Write-Warning -Value ${function:Write-McccWarning} -Force | Out-Null
  New-Item -Path Function:script:Write-Error -Value ${function:Write-McccError} -Force | Out-Null
  New-Item -Path Function:script:Read-Host -Value ${function:Read-McccHost} -Force | Out-Null
}

function ConvertTo-McccStringList {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object]$Value = $null
  )

  $result = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Value) { return @() }

  if (($Value -is [System.Collections.IEnumerable]) -and (-not ($Value -is [string]))) {
    foreach ($item in $Value) {
      $text = [string]$item
      if ([string]::IsNullOrWhiteSpace($text)) { continue }
      $result.Add($text.Trim()) | Out-Null
    }
    return ,@($result.ToArray())
  }

  $single = [string]$Value
  if (-not [string]::IsNullOrWhiteSpace($single)) {
    $result.Add($single.Trim()) | Out-Null
  }
  return ,@($result.ToArray())
}

function Test-McccUnsafeCrashWindowTitlePattern {
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  if ([string]::IsNullOrWhiteSpace($Pattern)) { return $true }

  # * A bare "Minecraft" pattern is too broad and matches normal game windows.
  $normalized = ([string]$Pattern).Trim().ToLowerInvariant()
  $normalized = $normalized -replace "[^a-z0-9]+", ""
  return ($normalized -eq "minecraft")
}

function Get-McccLocaleCrashWindowTitlePatternSet {
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory = $false)]
    [string]$StartDir = $PSScriptRoot,
    [Parameter(Mandatory = $false)]
    [string[]]$FallbackPatterns = @("Something broke")
  )

  if ([string]::IsNullOrWhiteSpace($StartDir)) {
    $StartDir = (Get-Location).Path
  }

  $patterns = New-Object System.Collections.Generic.List[string]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($item in (ConvertTo-McccStringList -Value $FallbackPatterns)) {
    if (Test-McccUnsafeCrashWindowTitlePattern -Pattern $item) { continue }
    if ($seen.Add($item)) {
      $patterns.Add($item) | Out-Null
    }
  }

  $root = Get-McccProjectRoot -StartDir $StartDir
  if ([string]::IsNullOrWhiteSpace($root)) {
    $root = $StartDir
  }

  $localeDir = Join-Path -Path $root -ChildPath "scripts\locales"
  if (-not (Test-Path -LiteralPath $localeDir)) {
    return [string[]]@($patterns.ToArray())
  }

  $localeFiles = Get-ChildItem -LiteralPath $localeDir -Filter "*.psd1" -File -ErrorAction SilentlyContinue | Sort-Object -Property Name
  foreach ($localeFile in $localeFiles) {
    $localeData = $null
    try {
      $localeData = Import-PowerShellDataFile -LiteralPath $localeFile.FullName
    }
    catch {
      continue
    }
    if ($null -eq $localeData) { continue }
    if (-not $localeData.ContainsKey("Ui")) { continue }
    if ($null -eq $localeData.Ui) { continue }

    $rawPatterns = $null
    if ($localeData.Ui -is [hashtable]) {
      if ($localeData.Ui.ContainsKey("CrashWindowTitlePatterns")) {
        $rawPatterns = $localeData.Ui["CrashWindowTitlePatterns"]
      }
    }
    elseif ($null -ne $localeData.Ui.PSObject -and $null -ne $localeData.Ui.PSObject.Properties) {
      $uiProp = $localeData.Ui.PSObject.Properties["CrashWindowTitlePatterns"]
      if ($null -ne $uiProp) {
        $rawPatterns = $uiProp.Value
      }
    }

    foreach ($pattern in (ConvertTo-McccStringList -Value $rawPatterns)) {
      if (Test-McccUnsafeCrashWindowTitlePattern -Pattern $pattern) { continue }
      if ($seen.Add($pattern)) {
        $patterns.Add($pattern) | Out-Null
      }
    }
  }

  return [string[]]@($patterns.ToArray())
}

function Get-McccCurrentLocale {
  if (-not $script:McccLocalizationState.Initialized) { return "en" }
  return [string]$script:McccLocalizationState.Locale
}
