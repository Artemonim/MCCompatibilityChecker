- archive/ - Legacy Launcher code
- doc/Algorithm.md - description of the algorithm
- scripts/ - main code
- scripts/locales/ - localization dictionaries (`*.psd1`)
- tests/ - Pester test suite
- tools/ - additional scripts

When changing scripts, check with `./checker.ps1 -NoLocales`
New console output lines should be added to the localization files; check with `./checker.ps1`.

Primary entrypoints:
- `./run.ps1` - user-facing launcher automation entrypoint.
- `./checker.ps1` - repository quality gate (`PSScriptAnalyzer` + locales + Pester).
- Useful checker flags: `-NoLocales`, `-NoPester`, and optional path arguments (for targeted checks).

Config workflow:
- Keep machine-specific paths and local settings in `config.local.ini` (git-ignored), not in `config.ini`.

Validation dependencies:
- `PSScriptAnalyzer` PowerShell module.
- `Pester` PowerShell module (unless `./checker.ps1 -NoPester`).
- Python 3.x (unless `./checker.ps1 -NoLocales`).

Known logs in `%APPDATA%\.tlauncher` (example absolute path: `C:\Users\Artem\AppData\Roaming\.tlauncher`):
- `logs/launcher.log` and rotated files `launcher.log.1` ... `launcher.log.10` - needed when TLauncher fails to start, update, authenticate, or download components.
- `legacy/Minecraft/game/logs/latest.log` - needed for current session issues (startup errors, mod loading, runtime exceptions, missing dependencies).
- `legacy/Minecraft/game/logs/YYYY-MM-DD-N.log.gz` (archived game logs) - needed when problem happened in a past session and `latest.log` is already overwritten.
- `legacy/Minecraft/game/logs/chatlog.json` - needed to inspect chat/events history and reproduce issues tied to commands or chat interactions.
- `legacy/Minecraft/game/crash-reports/crash-YYYY-MM-DD_HH.MM.SS-(client|server).txt` - needed for hard crashes of client/server with stack traces and crash context.
- `legacy/Minecraft/game/debug/disconnect-YYYY-MM-DD_HH.MM.SS-client.txt` - needed for multiplayer disconnect diagnostics (kicks, timeouts, handshake/protocol mismatches).

Console color classification (PowerShell):
- Green: success/completion (e.g., recovery finished, no issues found).
- Cyan: stage headers, progress, neutral informational steps.
- Yellow: warnings, user decisions, non-fatal problem states (crash/fabric/no-launch outcomes).
- Red: fatal errors, unrecoverable states, termination reasons.
- Gray: secondary details, cleanup steps, dry-run notes, neutral “no action” statuses.