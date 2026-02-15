Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Describe "Shared-Isolation-LogParsing Fabric dependency extraction" {
  BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath ".."))
    $scriptPath = Join-Path -Path $repoRoot -ChildPath "scripts\Shared-Isolation-LogParsing.ps1"
    . $scriptPath
  }

  It "extracts requiring and missing IDs from Russian Fabric dialog lines" {
    $lines = @(
      "Установите мод prickle, версию 21.11.1 или выше.",
      "Установите мод cicada, любую версию между 0.6.0 (включительно) и 1.0.0 (исключительно).",
      "Установите мод formations, версию 1.0.0 или выше.",
      "Мод 'AttributeFix' (attributefix) 21.11.1 требует версию 21.11.1 или выше мода prickle, который отсутствует!",
      "Мод 'Do a Barrel Roll' (do_a_barrel_roll) 3.8.3 требует любую версию между 0.6.0 (включительно) и 1.0.0 (исключительно) мода cicada, который отсутствует!",
      "Мод 'Formations Overworld' (formationsoverworld) 1.0.5 требует версию 1.0.0 или выше мода formations, который отсутствует!"
    )

    $requiring = @(Get-FabricRequiringModId -Lines $lines)
    $missing = @(Get-FabricMissingDependencyId -Lines $lines)

    $requiring | Should -Contain "attributefix"
    $requiring | Should -Contain "do_a_barrel_roll"
    $requiring | Should -Contain "formationsoverworld"

    $missing | Should -Contain "prickle"
    $missing | Should -Contain "cicada"
    $missing | Should -Contain "formations"
  }

  It "aggregates dependency dialog info for Russian log lines" {
    $lines = @(
      "Установите мод supermartijn642corelib, любую версию между 1.1.17 (включительно) и 1.2.0 (исключительно).",
      "Мод 'Item Collectors' (itemcollectors) 1.1.11 требует любую версию между 1.1.17 (включительно) и 1.2.0 (исключительно) мода supermartijn642corelib, который отсутствует!"
    )

    $info = Get-FabricDependencyDialogInfo -Lines $lines

    $info.HasMissingDeps | Should -BeTrue
    @($info.RequiringModIds) | Should -Contain "itemcollectors"
    @($info.MissingDepIds) | Should -Contain "supermartijn642corelib"
  }
}
