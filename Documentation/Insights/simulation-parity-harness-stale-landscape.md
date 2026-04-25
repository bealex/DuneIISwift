---
name: simulation-parity-harness-stale-landscape
description: The parity harness's host.landscapeAt closure must compose live spice + structure overlays on top of the save-time baseline; reading the static snapshot diverges from OpenDUNE's Map_GetLandscapeType once tiles drain or buildings appear.
type: reference
---

## The fact

OpenDUNE's `Map_GetLandscapeType(packed)` (`src/map.c:541`) reads `g_map[packed].groundTileID` live — so a tile that started as `LST_THICK_SPICE` and was drained down to bare returns `LST_NORMAL_SAND` on the next call. Structure footprints win: any tile covered by a structure returns `LST_STRUCTURE`.

The Swift parity harness exposes this oracle to scripted code (notably `Unit_StartMovement`'s SetSpeed slice in `Functions.swift makeCalculateRouteUnit`) via `host.landscapeAt`. If that closure is wired to a static, save-time `snapshotLandscape` array, it diverges from OpenDUNE the instant *any* tile transitions — and the divergence surfaces silently as different `movementSpeed[movementType]` rows feeding `Unit_SetSpeed`, which produces a different `movingSpeed` field with no script-trace fingerprint.

`SpiceMap.landscapeByte(at:)` is NOT a drop-in: it returns sand for every non-spice tile, so it loses baseline rock / mountain / wall information. The harness must compose the three layers itself.

## Why it matters

SAVE007 tick 14796 surfaced this as `unit[39].movingSpeed=67 vs 96` — Swift +29. The opcode-level u39 trace through tick 14800 was byte-identical to OpenDUNE's, ruling out script-side drift. Bisecting the writers of `movingSpeed` led to `Unit_SetSpeed`, whose input came from `landscapeAt(packed)` reading the snapshot's pre-drain value (`movementSpeed[harvester]=160` for `LST_THICK_SPICE`) instead of the live value (`=112` for `LST_NORMAL_SAND`).

Closing this single bug carried the parity ceiling **+505 ticks** (14795 → 15300) on the SAVE007 long-form test, all the way to a different drift class at tick 15301.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Simulation/ParityHarness.swift:runAgainst` — the static `landscapeAt` stub (passed to `Host(landscapeAt:)`) is only the placeholder for `tileEnterScore`. After `host` is constructed, the harness reassigns `host.landscapeAt` to a `[weak host]` closure that walks `host.structures.findArray` for structure footprints, then overlays `host.spiceMap.cells[packed]`, then falls through to the baseline. Same logic as `buildLandscape` but per-tile.
- `Code/Core/Sources/DuneIICore/Simulation/ParityHarness.swift:buildLandscape` — bulk variant used by the `compareLandscape` diagnostic; the per-tile closure mirrors its rules.
- `Code/Core/Tests/DuneIICoreTests/ParityHarnessTests.swift:saveSevenParityLandscapeFrontier` — the long-form test that surfaces this drift; pinned at 15300.

## Where it lives in the reference

- `Repositories/OpenDUNE/src/map.c:541` — `Map_GetLandscapeType` proper.
- `Repositories/OpenDUNE/src/unit.c:1088..1105` — `Unit_StartMovement` calling `Map_GetLandscapeType` and `Unit_SetSpeed`.
