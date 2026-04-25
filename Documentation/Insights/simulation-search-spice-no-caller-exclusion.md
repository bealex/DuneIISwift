---
name: simulation-search-spice-no-caller-exclusion
description: OpenDUNE's Map_SearchSpice has no caller-exclusion parameter; tile occupancy implicitly excludes a stationary caller because it is registered on the tile layer via Unit_UpdateMap.
type: reference
---

## The fact

`Map_SearchSpice` (`src/map.c:1117`) iterates the bounding box around a centre tile and, for each candidate, skips tiles where `Unit_Get_ByPackedTile(curPacked) != NULL`. It does NOT take a "skip this unit" parameter — the calling harvester is implicitly excluded from picking its *own* tile only because `Unit_UpdateMap` (`src/unit.c:2466..2525`) has already registered the harvester on that tile.

If a Swift port of this function adds an explicit `excludingUnit: Int` parameter and uses it to filter the unit-occupancy set, the caller's own tile becomes a *valid* pick — opposite to OpenDUNE's intent. The drift surfaces only when:

1. The caller is stationary on a spice tile (registered on the tile layer).
2. That tile has just transitioned THICK → THIN (drain) in the current tick.
3. The script then calls SearchSpice from within that same tick.

Condition (2) is important because while the caller's tile is LST_THICK_SPICE, OpenDUNE's "thick within distance 4" preference (`radius2`) would favour the caller's tile anyway — but skips it for being occupied. Both engines produce the same answer only because the "occupied" skip comes first. Once the tile drops to LST_SPICE at tick 3011 in SAVE007, the bug was invisible to the pool-state diff until a harvester queried it.

## Why it matters

SAVE007 tick 3011 `u39.targetMove=54699 vs 54441` stuck around as an "unexplained spice-map drift" for several sessions because the initial hypothesis was that the spice maps had silently desynced. A new per-tile `Map_GetLandscapeType` parity comparator (`ParityHarness.diffLandscape`) proved the landscape grids were *identical* through tick 3011 on both engines — forcing the real question: "same landscape, same unit position, why different SearchSpice result?" Answer: Swift was treating the caller's tile as pickable; OpenDUNE skipped it via tile-layer registration.

The general lesson: when porting OpenDUNE search routines that skip "occupied" tiles, preserve the tile-layer semantics literally. Don't introduce an explicit `excludingUnit` parameter unless the original has one — you'll paper over a bug the original relies on for correctness.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Scripting/Functions.swift:makeSearchSpice` — passes `excludingUnit: -1` to `findSpiceNear` so the occupancy set includes the caller, matching OpenDUNE.
- `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift:findSpiceNear` — still accepts `excludingUnit` for the gameplay `tickHarvesting` auto-seek caller (Swift-only convenience, gated off in parity mode).
- `Code/Core/Tests/DuneIICoreTests/ParityHarnessTests.swift:saveSevenParityLandscapeFrontier` — the 3050-tick diagnostic that exercises the fixed path.

## Where it lives in the reference

- `Repositories/OpenDUNE/src/map.c:1117..1182` — `Map_SearchSpice` proper. Note the unconditional `if (Unit_Get_ByPackedTile(curPacked) != NULL) continue;`.
- `Repositories/OpenDUNE/src/unit.c:2466..2525` — `Unit_UpdateMap` with `type == 1` sets `t->hasUnit = true; t->index = unit->o.index + 1` on the unit's current packed tile.
- `Repositories/OpenDUNE/src/script/general.c:325..336` — `Script_General_SearchSpice` passes the current object's packed tile straight into `Map_SearchSpice` with no exclusion.
