Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Describe "Restore-ModsFromLog" {
  BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath ".."))

    $newTestSandbox = {
      param(
        [Parameter(Mandatory = $true)]
        [string]$Name
      )

      $sandboxRoot = Join-Path -Path $TestDrive -ChildPath $Name
      $scriptsDir = Join-Path -Path $sandboxRoot -ChildPath "scripts"
      $toolsDir = Join-Path -Path $sandboxRoot -ChildPath "tools"
      $storageModsDir = Join-Path -Path $sandboxRoot -ChildPath "storage\Mods"
      $gameModsDir = Join-Path -Path $sandboxRoot -ChildPath "game\mods"
      $storageLegacyVersionDir = Join-Path -Path $storageModsDir -ChildPath "Legacy\1.21.11"
      $gameLegacyVersionDir = Join-Path -Path $gameModsDir -ChildPath "legacy\1.21.11"
      $legacyLogPath = Join-Path -Path $sandboxRoot -ChildPath "legacy.log"
      $configPath = Join-Path -Path $sandboxRoot -ChildPath "config.ini"
      $configLocalPath = Join-Path -Path $sandboxRoot -ChildPath "config.local.ini"

      foreach ($dirPath in @($sandboxRoot, $scriptsDir, $toolsDir, $storageModsDir, $gameModsDir, $storageLegacyVersionDir, $gameLegacyVersionDir)) {
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
      Set-Content -LiteralPath $legacyLogPath -Value "" -Encoding UTF8

      $scriptCopyMap = @{
        "scripts\Shared-Localization.ps1" = (Join-Path -Path $scriptsDir -ChildPath "Shared-Localization.ps1")
        "scripts\Shared-Config.ps1" = (Join-Path -Path $scriptsDir -ChildPath "Shared-Config.ps1")
        "scripts\Auto-Run-LegacyLauncher.Restore.ps1" = (Join-Path -Path $scriptsDir -ChildPath "Auto-Run-LegacyLauncher.Restore.ps1")
        "tools\Restore-ModsFromLog.ps1" = (Join-Path -Path $toolsDir -ChildPath "Restore-ModsFromLog.ps1")
      }
      foreach ($relativeSource in $scriptCopyMap.Keys) {
        $sourcePath = Join-Path -Path $repoRoot -ChildPath $relativeSource
        Copy-Item -LiteralPath $sourcePath -Destination $scriptCopyMap[$relativeSource] -Force
      }

      return [pscustomobject]@{
        Root = $sandboxRoot
        LegacyLogPath = $legacyLogPath
        RestoreScriptPath = (Join-Path -Path $toolsDir -ChildPath "Restore-ModsFromLog.ps1")
        StorageModsDir = $storageModsDir
        GameModsDir = $gameModsDir
        StorageLegacyVersionDir = $storageLegacyVersionDir
        GameLegacyVersionDir = $gameLegacyVersionDir
      }
    }

    $setTestJarFile = {
      param(
        [Parameter(Mandatory = $true)]
        [string]$Path
      )

      $parent = Split-Path -Path $Path -Parent
      if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
      }
      Set-Content -LiteralPath $Path -Value "fake-jar-content" -Encoding UTF8
    }

    $invokeTestRestore = {
      param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Sandbox,
        [Parameter(Mandatory = $false)]
        [datetime]$SinceTimestamp = [datetime]::MinValue
      )

      $invokeParams = @{
        NoExit = $true
      }
      if ($SinceTimestamp -ne [datetime]::MinValue) {
        $invokeParams["SinceTimestamp"] = $SinceTimestamp
      }

      $errors = @()
      & $Sandbox.RestoreScriptPath @invokeParams -ErrorVariable +errors

      return [pscustomobject]@{
        ExitCode = $global:LASTEXITCODE
        ErrorCount = @($errors).Count
      }
    }
  }

  It "restores storage legacy entries and ignores blank lines in legacy.log" {
    $sandbox = & $newTestSandbox -Name "blank-lines"
    $jarName = "alpha.jar"
    $storageLegacyPath = Join-Path -Path $sandbox.StorageLegacyVersionDir -ChildPath $jarName
    & $setTestJarFile -Path $storageLegacyPath

    Set-Content -LiteralPath $sandbox.LegacyLogPath -Value @(
      "2026-02-15 08:28:41",
      "",
      ("Moved culprit to storage legacy: {0}" -f $storageLegacyPath),
      ""
    ) -Encoding UTF8

    $result = & $invokeTestRestore -Sandbox $sandbox

    $result.ExitCode | Should -Be 0
    $result.ErrorCount | Should -Be 0
    (Test-Path -LiteralPath (Join-Path -Path $sandbox.StorageModsDir -ChildPath $jarName)) | Should -BeTrue
    (Test-Path -LiteralPath (Join-Path -Path $sandbox.GameModsDir -ChildPath $jarName)) | Should -BeTrue
    (Test-Path -LiteralPath $storageLegacyPath) | Should -BeFalse
  }

  It "restores jar from game legacy fallback entries" {
    $sandbox = & $newTestSandbox -Name "game-fallback"
    $jarName = "fallback.jar"
    $gameLegacyPath = Join-Path -Path $sandbox.GameLegacyVersionDir -ChildPath $jarName
    & $setTestJarFile -Path $gameLegacyPath

    Set-Content -LiteralPath $sandbox.LegacyLogPath -Value @(
      "2026-02-15 08:28:41",
      ("Storage legacy copy is unavailable. Moved culprit to game legacy fallback: {0}" -f $gameLegacyPath)
    ) -Encoding UTF8

    $result = & $invokeTestRestore -Sandbox $sandbox

    $result.ExitCode | Should -Be 0
    $result.ErrorCount | Should -Be 0
    (Test-Path -LiteralPath (Join-Path -Path $sandbox.GameModsDir -ChildPath $jarName)) | Should -BeTrue
    (Test-Path -LiteralPath $gameLegacyPath) | Should -BeFalse
  }

  It "respects SinceTimestamp when selecting restore entries" {
    $sandbox = & $newTestSandbox -Name "since-filter"
    $oldJarName = "old.jar"
    $newJarName = "new.jar"
    $oldLegacyPath = Join-Path -Path $sandbox.StorageLegacyVersionDir -ChildPath $oldJarName
    $newLegacyPath = Join-Path -Path $sandbox.StorageLegacyVersionDir -ChildPath $newJarName
    & $setTestJarFile -Path $oldLegacyPath
    & $setTestJarFile -Path $newLegacyPath

    Set-Content -LiteralPath $sandbox.LegacyLogPath -Value @(
      "2026-02-15 08:20:00",
      ("Moved culprit to storage legacy: {0}" -f $oldLegacyPath),
      "2026-02-15 08:40:00",
      ("Moved culprit to storage legacy: {0}" -f $newLegacyPath)
    ) -Encoding UTF8

    $result = & $invokeTestRestore -Sandbox $sandbox -SinceTimestamp ([datetime]"2026-02-15 08:40:00")

    $result.ExitCode | Should -Be 0
    $result.ErrorCount | Should -Be 0
    (Test-Path -LiteralPath $oldLegacyPath) | Should -BeTrue
    (Test-Path -LiteralPath (Join-Path -Path $sandbox.StorageModsDir -ChildPath $oldJarName)) | Should -BeFalse
    (Test-Path -LiteralPath (Join-Path -Path $sandbox.StorageModsDir -ChildPath $newJarName)) | Should -BeTrue
    (Test-Path -LiteralPath (Join-Path -Path $sandbox.GameModsDir -ChildPath $newJarName)) | Should -BeTrue
    (Test-Path -LiteralPath $newLegacyPath) | Should -BeFalse
  }
}
