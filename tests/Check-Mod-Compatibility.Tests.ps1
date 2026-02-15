Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Describe "Check-Mod-Compatibility safeguards" {
  BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath ".."))
    $powershellExe = (Get-Command -Name "powershell" -ErrorAction Stop).Source

    $newTestSandbox = {
      param(
        [Parameter(Mandatory = $true)]
        [string]$Name
      )

      $sandboxRoot = Join-Path -Path $TestDrive -ChildPath $Name
      $scriptsDir = Join-Path -Path $sandboxRoot -ChildPath "scripts"
      $toolsDir = Join-Path -Path $sandboxRoot -ChildPath "tools"
      $logsDir = Join-Path -Path $sandboxRoot -ChildPath "logs"
      $localesDir = Join-Path -Path $scriptsDir -ChildPath "locales"
      $storageModsDir = Join-Path -Path $sandboxRoot -ChildPath "storage\mods"
      $gameModsDir = Join-Path -Path $sandboxRoot -ChildPath "game\mods"
      $configPath = Join-Path -Path $sandboxRoot -ChildPath "config.ini"
      $configLocalPath = Join-Path -Path $sandboxRoot -ChildPath "config.local.ini"

      foreach ($dirPath in @($sandboxRoot, $scriptsDir, $toolsDir, $logsDir, $localesDir, $storageModsDir, $gameModsDir)) {
        if (-not (Test-Path -LiteralPath $dirPath)) {
          New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
        }
      }

      Set-Content -LiteralPath (Join-Path -Path $sandboxRoot -ChildPath "AGENTS.md") -Value "test sandbox" -Encoding UTF8
      Set-Content -LiteralPath $configPath -Value @(
        "[Paths]",
        ("StorageModsDir={0}" -f $storageModsDir),
        ("GameModsDir={0}" -f $gameModsDir),
        "",
        "[Localization]",
        "Language=en"
      ) -Encoding UTF8
      Set-Content -LiteralPath $configLocalPath -Value "" -Encoding UTF8

      $scriptCopyMap = @{
        "scripts\Shared-Localization.ps1" = (Join-Path -Path $scriptsDir -ChildPath "Shared-Localization.ps1")
        "scripts\Shared-Config.ps1" = (Join-Path -Path $scriptsDir -ChildPath "Shared-Config.ps1")
        "scripts\Shared-LogTools.ps1" = (Join-Path -Path $scriptsDir -ChildPath "Shared-LogTools.ps1")
        "scripts\Shared-Isolation-LogParsing.ps1" = (Join-Path -Path $scriptsDir -ChildPath "Shared-Isolation-LogParsing.ps1")
        "scripts\Shared-Isolation-Legacy.ps1" = (Join-Path -Path $scriptsDir -ChildPath "Shared-Isolation-Legacy.ps1")
        "scripts\Shared-Isolation-JarDependencies.ps1" = (Join-Path -Path $scriptsDir -ChildPath "Shared-Isolation-JarDependencies.ps1")
        "scripts\Check-Mod-Compatibility.ps1" = (Join-Path -Path $scriptsDir -ChildPath "Check-Mod-Compatibility.ps1")
        "scripts\locales\en.psd1" = (Join-Path -Path $localesDir -ChildPath "en.psd1")
      }
      foreach ($relativeSource in $scriptCopyMap.Keys) {
        $sourcePath = Join-Path -Path $repoRoot -ChildPath $relativeSource
        Copy-Item -LiteralPath $sourcePath -Destination $scriptCopyMap[$relativeSource] -Force
      }

      return [pscustomobject]@{
        Root = $sandboxRoot
        CheckScriptPath = (Join-Path -Path $scriptsDir -ChildPath "Check-Mod-Compatibility.ps1")
        LogsDir = $logsDir
        StorageModsDir = $storageModsDir
        GameModsDir = $gameModsDir
      }
    }

    $newTestFabricJar = {
      param(
        [Parameter(Mandatory = $true)]
        [string]$JarPath,
        [Parameter(Mandatory = $true)]
        [string]$ModId,
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$ProvidedModIds = @(),
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$NestedJarEntries = @(),
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$ExtraJsonEntries = @()
      )

      $parent = Split-Path -Path $JarPath -Parent
      if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
      }

      Add-Type -AssemblyName System.IO.Compression
      Add-Type -AssemblyName System.IO.Compression.FileSystem

      $fs = [System.IO.File]::Open($JarPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
      $zip = $null
      try {
        $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)

        $modJson = [ordered]@{
          schemaVersion = 1
          id = $ModId
          version = "1.0.0"
          name = $ModId
        }
        if ($ProvidedModIds.Count -gt 0) {
          $modJson["provides"] = @($ProvidedModIds)
        }
        if ($NestedJarEntries.Count -gt 0) {
          $modJson["jars"] = @($NestedJarEntries | ForEach-Object { @{ file = $_ } })
        }

        $modJsonText = $modJson | ConvertTo-Json -Depth 10 -Compress
        $modEntry = $zip.CreateEntry("fabric.mod.json")
        $modWriter = New-Object System.IO.StreamWriter($modEntry.Open(), [System.Text.Encoding]::UTF8)
        try {
          $modWriter.Write($modJsonText)
        } finally {
          $modWriter.Dispose()
        }

        foreach ($nestedEntryPath in @($NestedJarEntries)) {
          $entryPath = [string]$nestedEntryPath
          if ([string]::IsNullOrWhiteSpace($entryPath)) { continue }
          $nestedEntry = $zip.CreateEntry($entryPath.Replace("\", "/"))
          $nestedWriter = New-Object System.IO.StreamWriter($nestedEntry.Open(), [System.Text.Encoding]::UTF8)
          try {
            $nestedWriter.Write("nested-placeholder")
          } finally {
            $nestedWriter.Dispose()
          }
        }

        foreach ($extraEntryPath in @($ExtraJsonEntries)) {
          $entryPath = [string]$extraEntryPath
          if ([string]::IsNullOrWhiteSpace($entryPath)) { continue }
          $extraEntry = $zip.CreateEntry($entryPath.Replace("\", "/"))
          $extraWriter = New-Object System.IO.StreamWriter($extraEntry.Open(), [System.Text.Encoding]::UTF8)
          try {
            $extraWriter.Write("{}")
          } finally {
            $extraWriter.Dispose()
          }
        }
      } finally {
        if ($null -ne $zip) { $zip.Dispose() }
        $fs.Dispose()
      }
    }

    $invokeCheckCompatibility = {
      param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Sandbox,
        [Parameter(Mandatory = $true)]
        [string]$LogPath
      )

      $output = & $powershellExe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $Sandbox.CheckScriptPath `
        -LogPath $LogPath `
        -GameModsDir $Sandbox.GameModsDir `
        -StorageModsDir $Sandbox.StorageModsDir `
        -SkipGameLogs `
        -DependencyMapSource Internal `
        -NoLegacy 2>&1

      return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output | ForEach-Object { [string]$_ })
      }
    }
  }

  It "avoids broad nested fallback matches for cardinal-components-entity" {
    $sandbox = & $newTestSandbox -Name "cardinal-fallback-safety"
    $logPath = Join-Path -Path $sandbox.LogsDir -ChildPath "tl-logger.txt"

    $cardinalBundleName = "cardinal-wrapper.jar"
    $fabricApiName = "fabric-api.jar"
    $gameCardinalBundlePath = Join-Path -Path $sandbox.GameModsDir -ChildPath $cardinalBundleName
    $storageCardinalBundlePath = Join-Path -Path $sandbox.StorageModsDir -ChildPath $cardinalBundleName
    $gameFabricApiPath = Join-Path -Path $sandbox.GameModsDir -ChildPath $fabricApiName
    $storageFabricApiPath = Join-Path -Path $sandbox.StorageModsDir -ChildPath $fabricApiName

    & $newTestFabricJar `
      -JarPath $gameCardinalBundlePath `
      -ModId "cardinal-wrapper" `
      -NestedJarEntries @("META-INF/jars/cardinal-components-entity-3.0.0.jar")
    Copy-Item -LiteralPath $gameCardinalBundlePath -Destination $storageCardinalBundlePath -Force

    & $newTestFabricJar `
      -JarPath $gameFabricApiPath `
      -ModId "fabric-api" `
      -ProvidedModIds @("fabric") `
      -NestedJarEntries @("META-INF/jars/fabric-entity-events-v1.jar")
    Copy-Item -LiteralPath $gameFabricApiPath -Destination $storageFabricApiPath -Force

    Set-Content -LiteralPath $logPath -Value @(
      "[09:43:44] [main/ERROR]: Mixin apply for mod cardinal-components-entity failed mixins.cardinal_components_entity.json:common.MixinEntity from mod cardinal-components-entity -> net.minecraft.class_1297: org.spongepowered.asm.mixin.injection.throwables.InvalidInjectionException"
    ) -Encoding UTF8

    $result = & $invokeCheckCompatibility -Sandbox $sandbox -LogPath $logPath

    $result.ExitCode | Should -Be 0
    (Test-Path -LiteralPath $gameFabricApiPath) | Should -BeTrue
    (Test-Path -LiteralPath $storageFabricApiPath) | Should -BeTrue
    (Test-Path -LiteralPath $gameCardinalBundlePath) | Should -BeFalse
    (Test-Path -LiteralPath $storageCardinalBundlePath) | Should -BeFalse
  }

  It "ignores suppressed entrypoint wrapper evidence for fabric api modules" {
    $sandbox = & $newTestSandbox -Name "suppressed-wrapper-filter"
    $logPath = Join-Path -Path $sandbox.LogsDir -ChildPath "tl-logger.txt"

    $roadweaverJarName = "roadweaver-fabric.jar"
    $fabricApiJarName = "fabric-api.jar"
    $gameRoadweaverPath = Join-Path -Path $sandbox.GameModsDir -ChildPath $roadweaverJarName
    $storageRoadweaverPath = Join-Path -Path $sandbox.StorageModsDir -ChildPath $roadweaverJarName
    $gameFabricApiPath = Join-Path -Path $sandbox.GameModsDir -ChildPath $fabricApiJarName
    $storageFabricApiPath = Join-Path -Path $sandbox.StorageModsDir -ChildPath $fabricApiJarName

    & $newTestFabricJar `
      -JarPath $gameRoadweaverPath `
      -ModId "roadweaver" `
      -ExtraJsonEntries @("roadweaver.mixins.json")
    Copy-Item -LiteralPath $gameRoadweaverPath -Destination $storageRoadweaverPath -Force

    & $newTestFabricJar `
      -JarPath $gameFabricApiPath `
      -ModId "fabric-api" `
      -ProvidedModIds @("fabric", "fabric-networking-api-v1")
    Copy-Item -LiteralPath $gameFabricApiPath -Destination $storageFabricApiPath -Force

    Set-Content -LiteralPath $logPath -Value @(
      "[10:39:15] [Render thread/ERROR]: Mixin apply for mod roadweaver failed roadweaver.mixins.json:fabric.MinecraftServerMixin from mod roadweaver -> net.minecraft.server.MinecraftServer: org.spongepowered.asm.mixin.injection.throwables.InvalidInjectionException",
      "Suppressed: net.fabricmc.loader.api.EntrypointException: Exception while loading entries for entrypoint 'main' provided by 'fabric-networking-api-v1'"
    ) -Encoding UTF8

    $result = & $invokeCheckCompatibility -Sandbox $sandbox -LogPath $logPath

    $result.ExitCode | Should -Be 0
    (Test-Path -LiteralPath $gameRoadweaverPath) | Should -BeFalse
    (Test-Path -LiteralPath $storageRoadweaverPath) | Should -BeFalse
    (Test-Path -LiteralPath $gameFabricApiPath) | Should -BeTrue
    (Test-Path -LiteralPath $storageFabricApiPath) | Should -BeTrue
  }

  It "isolates duplicate modId jars one-by-one per run" {
    $sandbox = & $newTestSandbox -Name "kiwi-single-step"
    $logPath = Join-Path -Path $sandbox.LogsDir -ChildPath "tl-logger.txt"

    $kiwiJarNames = @(
      "Kiwi-1.21-Fabric-15.1.5.jar",
      "Kiwi-1.21.1-Fabric-15.8.2.jar"
    )

    foreach ($jarName in $kiwiJarNames) {
      $gameJarPath = Join-Path -Path $sandbox.GameModsDir -ChildPath $jarName
      $storageJarPath = Join-Path -Path $sandbox.StorageModsDir -ChildPath $jarName

      & $newTestFabricJar `
        -JarPath $gameJarPath `
        -ModId "kiwi" `
        -ExtraJsonEntries @("kiwi.mixins.json")
      Copy-Item -LiteralPath $gameJarPath -Destination $storageJarPath -Force
    }

    Set-Content -LiteralPath $logPath -Value @(
      "[09:41:06] [main/ERROR]: Mixin apply for mod kiwi failed kiwi.mixins.json:client.ScreenMixin from mod kiwi -> net.minecraft.class_437: org.spongepowered.asm.mixin.injection.throwables.InvalidInjectionException"
    ) -Encoding UTF8

    $result = & $invokeCheckCompatibility -Sandbox $sandbox -LogPath $logPath

    $result.ExitCode | Should -Be 0
    @(Get-ChildItem -LiteralPath $sandbox.GameModsDir -Filter "Kiwi*.jar" -File -ErrorAction SilentlyContinue).Count | Should -Be 1
    @(Get-ChildItem -LiteralPath $sandbox.StorageModsDir -Filter "Kiwi*.jar" -File -ErrorAction SilentlyContinue).Count | Should -Be 1
  }
}
