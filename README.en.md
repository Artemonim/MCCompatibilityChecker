# MCCompatibilityChecker

[Русский](README.md) | [English](README.en.md) | [Español](README.es.md) | [Tiếng Việt](README.vi.md) | [Português](README.pt.md) | [Türkçe](README.tr.md) | [Indonesia](README.id.md) | [中文](README.zh.md)

Automatic Minecraft mod conflict diagnostics. The script launches the game, catches crashes, reads crash logs, finds the culprit mod, and isolates it — in a loop until the assembly works.

> Works via [Legacy Launcher](https://llaun.ch/) (successor to TLauncher). Game launch and crash detection are handled through the launcher's GUI; error analysis is based on standard Fabric/Forge/Minecraft logs.

## Why

You've gathered 200 mods, launched the game — and it crashed. You opened the log — and it's a wall of text. You removed a mod at random — and got another crash. Sound familiar?

MCCompatibilityChecker does what you do manually, but automatically: removes mods, launches the game, checks the result, and repeats. But instead of random attempts, it uses an algorithm with binary search, Mixin error analysis, and a dependency map.

The result is a list of culprits and a working assembly.

## Project Status

Current version — active development (experimental).

- Currently, processing large clusters of incompatibilities may be unstable.
- For large modpacks, it is recommended to back up the `mods` folder first and use reports/logs after each run.

## How it Works

Diagnostics proceed in several stages. Each subsequent stage is enabled only if the previous one didn't solve the problem:

1. **Baseline Analysis** — reads the crash log, looks for candidates in the error text, and isolates them in dependency-priority order.
2. **Mixin Analysis** — parses `Mixin apply failed` and `@Mixin target not found` errors, identifies the source and target mods, and checks each in 1–2 launches.
3. **Layering** — removes all mods, leaves core libraries, and adds the rest in layers (by dependency levels, exponential batches). On batch crash — triage and isolation within the batch.
4. **Isolation** — fallback: dependency-aware levels, exponential/binary probes at early levels, and linear isolation at later levels.
5. **Recovery** — if 3+ "culprits" yield the same Mixin error, the script checks if they were false positives and looks for the true root cause.

Detailed algorithm description — in [doc/Algorithm.md](doc/Algorithm.md).

## Requirements

- **Windows** (Win32 UI Automation is used)
- **PowerShell 5.1+**
- **Legacy Launcher** ([llaun.ch](https://llaun.ch/))
- Minecraft with **Fabric** or **Forge**

## Dev Dependencies

- **PSScriptAnalyzer** (PowerShell module, needed for `checker.ps1`)
- **Python 3.x** (needed for localization checks via `tools/Check-Localization.py`)

Installing `PSScriptAnalyzer`:
```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

## Quick Start

1. Clone the repository or download the archive from the [latest release](https://github.com/Artemonim/MCCompatibilityChecker/releases/latest):
   ```bash
   git clone https://github.com/Artemonim/MCCompatibilityChecker.git
   ```

2. Copy `config.ini` to `config.local.ini` and specify the path to your mods folder:
   ```ini
   [Paths]
   GameModsDir=%APPDATA%\.tlauncher\legacy\Minecraft\game\mods
   ```

3. Open Minecraft Launcher.

4. Type `./run.ps1` or `./run.ps1 -verbose` in the PowerShell console.

5. Hover your mouse over the client launch button in the launcher.

6. Press `Enter` to send the console command and let the Checker get the button coordinates.

## Configuration

Settings are defined in `config.ini` (defaults) and `config.local.ini` (your overrides, ignored by git).

| Parameter | Description |
|-----------|-------------|
| `GameModsDir` | The mods folder used by the game |
| `StorageModsDir` | Main mod storage (optional) |
| `LogPath` | Path to the launcher log file (empty for auto-detection) |
| `LauncherExePath` | Path to the launcher executable (empty to connect to a running one) |
| `EnableMixinAnalysis` | Enable Mixin analysis stage (default: `true`) |
| `EnableLayering` | Enable Layering and subtractive Isolation (default: `true`) |
| `EnableRecovery` | Enable Recovery of phantom culprits (default: `false`) |
| `Language` | Language for console messages (`[Localization].Language`). If empty: auto-detect from OS, fallback to `en` |

Available locales: `en`, `ru`.
Stubs prepared for: `tr_TR`, `pt_BR`, `vi`, `es_ES`, `id_ID`, `zh-CN`.
The search for the launcher's crash window automatically gathers patterns from `scripts/locales/*.psd1` (`Ui.CrashWindowTitlePatterns`).
Currently includes `Something broke` / `Something went wrong` (en) and `Что-то сломалось...` (ru). For new languages, just add this list to the corresponding locale file.
If your launcher window has a different title, you can explicitly set `CrashWindowTitlePatterns` in `[Profile:<name>]` and run with `-Profile <name>`.

## Main Launch Parameters

```bash
.\run.ps1 -Help          # Brief help
.\run.ps1 -HelpFull      # Full technical help
```

| Flag | Description |
|------|-------------|
| `-LauncherExePath <path>` | Path to launcher (if not specified in config) |
| `-NoLegacy` | Do not save isolated mods — delete them |
| `-GameLegacy` | Keep copies of isolated mods in the game folder |
| `-DryRun` | Show what will be done without actual execution |
| `-Verbose` | Detailed logs (to console and `MCCC.log`) |
| `-UseLinearIsolation` | Linear search instead of binary (slower but simpler) |
| `-NoCache` | Disable session cache (re-verify even previously successful configurations) |
| `-ThoroughStabilityCheck` | Increase the stability check window for launches |
| `-AutoHandleFabricDialog <bool>` | Auto-route Fabric dialogs without missing deps in the debug pipeline |
| `-IgnoreModIds <id1,id2,...>` | Ignore specified mod IDs in compatibility cleanup |
| `-Profile <name>` | Apply profile from `[Profile:<name>]` in `config.ini` / `config.local.ini` |

## Script and Localization Check

`checker.ps1` checks:
- PowerShell scripts via `PSScriptAnalyzer`
- Localization assets via `tools/Check-Localization.py`
- `Write-Verbose`/debug-only strings are considered service strings, remain in English, and are not included in localization coverage.

Examples:
```powershell
.\checker.ps1             # Full check (including locales)
.\checker.ps1 -NoLocales  # Skip locale check
```

Behavior when Python is missing:
- By default, this is an **error** (checker exits with an error code) to avoid breaking the localization system.
- If you are not working with localization, use `-NoLocales`.

## Project Structure

```
├── run.ps1                  # Entry point
├── config.ini               # Default configuration
├── checker.ps1              # Linter + localization check
├── scripts/
│   ├── Auto-Run-LegacyLauncher.ps1      # Orchestrator: launch, monitoring, loop
│   ├── Check-Mod-Compatibility.ps1      # Baseline Analysis
│   ├── Analyze-MixinErrors.ps1          # Mixin Analysis
│   ├── Layer-Mods.ps1                   # Layering
│   ├── Isolate-Incompatible-Mod.ps1     # Isolation (fallback)
│   ├── Recover-PhantomCulprits.ps1      # Recovery
│   └── Shared-*.ps1                     # Shared modules
├── tools/
│   ├── Analyze-JarDependencies.ps1      # JAR dependency analysis
│   ├── Analyze-JarDependencyMap.ps1     # Dependency map building
│   └── Restore-ModsFromLog.ps1          # Mod restoration from report
└── doc/
    └── Algorithm.md                     # Detailed algorithm description
```

## Where Isolated Mods Go

By default, isolated mods are moved to the `Legacy` folder inside `StorageModsDir` (or `GameModsDir` if storage is not set). This allows for easy manual restoration if the diagnostic result does not satisfy you.

The `-NoLegacy` flag deletes mods permanently. The `-GameLegacy` flag additionally saves a copy in the game folder.

## Final Summary Report

Upon completion, the script outputs a report: execution time, list of culprits by stage, restored mods (if Recovery was used), and the current list of isolated mods.

## Limitations

- Works only with Legacy Launcher (GUI automation is tied to its interface)
- Windows only (Win32 API for window management)
- Diagnostics require multiple game launches — on large modpacks, this can take significant time
- With large clusters of incompatibilities, unstable runs and early fallback/stop of diagnostics are possible
- The Recovery stage is currently experimental and disabled by default

## License

MIT
