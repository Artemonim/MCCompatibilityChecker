# Diagnostic Algorithm

This document describes the complete cycle of automatic mod conflict diagnostics — from startup to the final report.

## General Cycle

1. The launcher is open, and the user runs the script in the terminal.
2. Before clicking, the script closes old crash/Fabric windows remaining from previous runs.
3. The script waits for the cursor to be positioned over the launch button and clicks it.
4. After the click, the script waits for one of several outcomes: a crash (crash window), a Fabric dialog (missing dependencies), or a successful launch.
5. Detection of crash/Fabric windows is prioritized to the launcher process (fallback is a general search) to avoid catching "foreign" system windows.
6. If there is no crash and the session still has isolated mods, Recovery runs automatically (when enabled).
7. A user dialog appears only when unresolved isolated mods remain, Recovery is disabled, or the launch outcome is ambiguous (Fabric/NoLaunch).
8. For sessions ending with Fabric missing dependencies, the script shows a final choice: `continue` / `rollback` / `finish`.

## Separate Update Mode (`.\run.ps1 -Update <path>`)

A separate scenario for batch updating mods from `StorageModsDir` starting from a selected time anchor.

### Steps

1. Pre-launch check:
- A trial launch is performed before any file changes.
- If `CrashDialog` or `NoLaunch` occurs: a modal dialog shows `Fix / Cancel`.
  - `Fix` → runs the standard pipeline (`Auto-Run-LegacyLauncher.ps1`).
  - `Cancel` → exits update mode without changes.
- If a Fabric dialog with missing dependencies occurs: a modal dialog shows `Fix / Cancel`.
  - `Fix` → runs the standard pipeline (`Auto-Run-LegacyLauncher.ps1`).
  - `Cancel` → exits update mode without changes.

2. Selecting update candidates:
- `UpdatePath` must point to a `.jar` in the root of `StorageModsDir` (non-recursive).
- Processing includes the anchor itself and all newer `.jar` files: `LastWriteTime >= anchor.LastWriteTime`.

3. Candidate classification:
- For each candidate, jar metadata (`id`/`provides`) is read via jar analyzers.
- Candidates are divided into groups:
  - `replaceable` — an older version was found in `StorageModsDir` and/or `GameModsDir` (rollback source exists).
  - `new-only` — no older versions found.

4. Applying and stabilizing the `replaceable` batch:
- For each `replaceable` candidate:
  - Older versions in `StorageModsDir` (root only) are moved to `Updated/<MinecraftVersion>`,
  - Older versions in `GameModsDir` are removed (with backup to `Updated/<MinecraftVersion>`),
  - New version is copied to `GameModsDir`.
- After applying, a post-check is performed:
  - Targeted rollback by signals from logs (missing/requiring/incompatible mod IDs),
  - Rollback-layering in batches `1, 2, 4, ...` until stabilization,
  - Rollback-set minimization (one old version at a time).

5. Applying `new-only` and final verification:
- After `replaceable` stabilization, `new-only` mods are added (no old version rollback available for them).
- After `new-only`, a post-launch check runs:
  - on failure it offers switching to the standard pipeline (`Auto-Run-LegacyLauncher.ps1`),
  - on success with no active rollback set, update mode ends without an extra final launch.

## Stage 1: Baseline Analysis

The script reads the crash log and searches for mod names in the error text.

- If a mod is found and exists in `game/mods`, the script isolates it (moves it to Legacy) and tries launching again.
- If a mod is found but not in `game/mods`, it proceeds to Mixin analysis.
- Candidates are processed in a conflict-dependent priority:
  - First by "conflict weight" from Fabric/logs (number and type of evidence strings, links with other mod IDs).
  - Then by dependency priority (tier and number of dependents).
  - If equal, by modification date.

### Fabric conflict-priority (Important)

For Fabric dialogs, additional heuristics are applied to avoid removing secondary mods before the root cause.

- If a mod ID appears only as `Remove/Replace` (or `Fix: add/remove/replace`) and clearly "references" another more conflict-heavy mod ID, that mod ID is marked as secondary and **deferred** in the current iteration.
- This reduces false removals such as Fabric suggesting to remove `iris`, while the primary conflict is caused by `immersive_portals`, which would be isolated first anyway.
- Deferred secondary mod IDs are logged separately (`Fabric conflict-priority deferred secondary mod IDs: ...`).

## Stage 2: Mixin Analysis

> Script: `Analyze-MixinErrors.ps1`

Target strategy: parsing Mixin errors from the crash log. A cheap check — 1–2 runs per error. Runs before layering.

### Parsing Errors

The script looks for two types of lines in the log:

- **`Mixin apply for mod <mod_id> failed ... from mod ... -> <class>`** — a mod tried to apply a Mixin and failed.
- **`@Mixin target <class> was not found ... from mod <mod_id>`** — the target class for the Mixin was not found.

`Mixin apply failed` errors are processed first as a more reliable root-cause signal.

### Resolving mod ID → JAR

1. First, through the dependency map (built from `fabric.mod.json`).
2. If not resolved, fallback to scanning JAR files:
   - Reading `fabric.mod.json` of external and nested (`jars`) mods.
   - Building a lookup by `id`/`provides` and mixin config names (`*.mixins.json`, `mixin.*.json`).

### Determining target class owner

For the target class, the owner mod is determined by a heuristic: segments of the full class name are matched against known mod IDs.

### Verification

1. Remove the source mod, launch the client.
   - Stable → source mod = culprit → move to Legacy, return to the main loop.
   - Crashes → restore source, try target mod.
2. Remove the target mod, launch the client.
   - Stable → target mod = culprit → move to Legacy, return to the main loop.
   - Crashes → restore target, Mixin analysis did not help → proceed to Layering.

## Stage 3: Layering (Additive)

> Script: `Layer-Mods.ps1`

Additive strategy: start with a minimum (core libraries), add mods in layers.

### Mod Classification by Dependencies

Mods are divided into tiers based on the number of mods depending on them:

| Tier | Criterion | Role |
|------|-----------|------|
| 4 (core) | >10 others depend on it | Core libraries (Fabric API, Cloth Config, etc.) |
| 3 | ≤10 depend on it | Popular libraries |
| 2 | ≤3 depend on it | Mods with a few dependents |
| 1 | No one depends on it | Final mods |

Within each tier, mods are sorted from oldest to newest by modification date.

### Core Library Check

Everything except tier 4 mods is isolated. A baseline launch is performed with core libraries + hash-cached mods for speed.

- If the baseline fails, a retry is performed in strict core-only mode.
- If strict core-only also fails, the process stops — the problem is in the core libraries, and manual diagnostics are required.

### Main Process (Tier 3 → Tier 2 → Tier 1)

Mods are added in exponential batches: 1, 2, 4, 8, ...

**On Fabric Dialog** (missing dependencies):

- The script searches isolated mods for those Fabric marks as missing (`requires ... which is missing`) and restores them strictly by mod ID.
- If a Crash occurs after restoring dependencies, a separate Crash Isolation is launched within the current batch (on requiring candidates, considering tier priority).
- If the dialog does not go away after retries, the batch returns to quarantine.
- After 3 consecutive unresolvable Fabric batches in one tier, the tier stops.
- If there were unresolvable batches, Layering completes with code 3 (incomplete), and a fallback is launched.

**On Crash:**

1. Baseline algorithm: read the log, find the culprit mod.
2. If the log did not help, exponential binary Isolation within the batch (iterative, supports multiple culprits).
3. For in-depth Tier 1 diagnostics: temporarily isolate all already active Tier 1 mods except the problematic batch.
4. After batch diagnostics, restore temporarily isolated mods and perform a control launch.
5. Found culprit → move to Legacy, Layering continues.

**On Successful Launch:**

- 20 seconds wait to confirm stability (60 with `-LongLaunchTimeout`; alias: `-ThoroughStabilityCheck`).
- The client closes, and the script proceeds to the next layer.
- If the player closes the game themselves, the batch is considered clean.
- On the final batch of the last tier, the game remains running.

### Fallback

If Layering fails completely, the script switches to subtractive Isolation.

## Stage 4: Isolation (Hybrid Subtractive)

> Script: `Isolate-Incompatible-Mod.ps1`

Reverse strategy (fallback): a dependency-aware hybrid that combines exponential probes, binary narrowing, and linear isolation.

### Order and Modes

Mods are divided into dependency-aware groups (lower "dependency weight" first):

| Group | Criterion |
|-------|-----------|
| 1 | No one depends on it (0) |
| 2 | ≤3 depend on it |
| 3 | ≤10 depend on it |
| 4 | Core libraries (rest) |

Within a group, sorted from newest to oldest by modification date.

Default Isolation Mode:

- For early groups, an exponential probe (`1, 2, 4, ...`) with binary narrowing to a threshold is used.
- For late groups, linear Isolation (one mod at a time).
- On Fabric dependency dialog, the script:
  - Restores the removed missing dependency (if its removal caused the dialog).
  - Quick-isolates the requiring mod(s).
  - Continues the cycle.
- If a confirmed culprit is in dependency Tier 2+, mods that depend on it are automatically added to the exclusion queue (transitively via the dependency map).

### Stopping Criterion

When a successful launch occurs during an exclusion, or a confirmed change in the error signature is detected, a culprit/candidate is fixed.

## Stage 5: Recovery

> Script: `Recover-PhantomCulprits.ps1`

Post-Isolation: checks if the found culprits were "false positives" due to a shared Mixin error. Runs after Layering/Isolation when 3+ culprits are found, and also after a clean launch if isolated mods still remain in the current session.

### Logic

1. Culprits are grouped by matching Mixin error (`CrashEvidenceKey`).
2. For groups of 3+ culprits with the same `@Mixin target` error:
   - Source/target mod is extracted from the error and resolved to a JAR.
   - The suspected root-cause mod is removed from `game/mods`.
   - All phantom culprits in the group are restored.
   - Launch the client.
3. If stable → root-cause confirmed: move it to Legacy, culprits restored.
4. If crashes → rollback: remove culprits again, restore the root-cause.

## Final Summary

The report includes:

- Session start and end time, total duration.
- Culprits categorized by stage (Mixin analysis / Layering / Isolation / Recovery).
- Restored mods (Recovery) — as a separate list with a `+` sign.
- Current list of isolated mods.

---

## Summary Diagram

```
Launch → Crash?
  │
  ├─ Baseline Analysis → Mod found? → Isolate → Restart launch
  │
  ├─ Mixin Analysis → Source/target mod → Check one by one (1–2 runs)
  │
  ├─ Layering → Core → +Tier 3 → +Tier 2 → +Tier 1
  │   └─ On batch crash: Log analysis → Binary search within batch
  │
  ├─ Isolation (fallback) → Exp/Binary + Linear
  │
  └─ Recovery → Grouping by Mixin error → Root-cause check
```
