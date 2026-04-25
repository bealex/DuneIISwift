---
name: simulation-winger-offmap-removal
description: Unit_Move's off-map handler has TWO removal gates, not one — mustStayInMap=true wingers still get freed if they're save-initial and unlinked with script.variables[4]==0. Tile_IsValid is a high-bit mask, not a tile-index bounds check.
type: reference
---

## The fact

OpenDUNE's `Unit_Move` (`src/unit.c:1305..1317`) removes a winger that would step off the 64×64 map via *two* separate gates — a naive port that only checks `!mustStayInMap` leaves save-initial CARRYALLs and ORNITHOPTERs stuck in the pool forever. The full logic:

```c
if (!Tile_IsValid(newPosition)) {
    if (!ui->flags.mustStayInMap) {
        Unit_Remove(unit);                  // Gate 1
        return true;
    }
    if (unit->o.flags.s.byScenario &&
        unit->o.linkedID == 0xFF &&
        unit->o.script.variables[4] == 0) {
        Unit_Remove(unit);                  // Gate 2
        return true;
    }
    newPosition = unit->o.position;
    Unit_SetOrientation(...random bounce...);
}
```

Rows that set `mustStayInMap = true` in `src/table/unitinfo.c`: **only CARRYALL (row 0) and ORNITHOPTER (row 1)**. Every other unit — bullets, missiles, sandworm, fremen — falls into gate 1 and gets removed on the first off-map step. For CARRYALLs / ORNITHOPTERs, gate 2 still removes them when they're save-initial escorts that haven't been given a pickup target (`linkedID == 0xFF`) and their script hasn't latched `variables[4]` to a non-zero "active mission" flag.

`Tile_IsValid` itself is the other gotcha (`src/tile.h:14`):

```c
#define Tile_IsValid(tile) ((((tile).x | (tile).y) & 0xc000) == 0)
```

This is a high-bit mask, not a `tileX < 64` comparison. Valid positions have `x < 0x4000 && y < 0x4000` — since each tile spans 256 pixel units and the map is 64 tiles wide, `tile_x >= 64` means `pos.x >= 16384 = 0x4000`, tripping bit 14 of the 0xC000 mask. Translating the macro to `pos.x >= 0x4000 || pos.y >= 0x4000` is equivalent; converting to tile-index bounds (`tileX >= 64 || tileY >= 64`) after a `>> 8` shift also works but loses the "wrapped-negative UInt16" case the mask naturally catches.

## Why it matters

SAVE007 u0 (CARRYALL) flies east from tile ~(56, 5) at tick 0 and crosses the east edge around tick 367. In OpenDUNE it hits gate 2 (`byScenario=true && linkedID==0xFF && variables[4]==0`) and gets `Unit_Remove`'d. In an early Swift port that only checked `!mustStayInMap`, u0 flew off forever — `host.units.findArray` kept growing every time the script tried to move it back on-map, and `house[1].unitCount` drifted from 6 (OpenDUNE) to 7 (Swift).

This is invisible to every other field in the pool-state diff because the stale unit's own state doesn't diverge (it just has nonsense off-map coordinates). Only a `compareHouse.unitCount` diff surfaces it — and that diff is impossible to pass without the correct port.

The general lesson: when OpenDUNE gives you a two-gate removal, port both or lose parity at a distance of ~370 ticks per save-initial idle winger.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Simulation/UnitInfo.swift` — `mustStayInMap: Bool` field; set to `true` on rows 0 (CARRYALL) and 1 (ORNITHOPTER), default `false` for everyone else.
- `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift:tickMovement` — winger step path now checks `(next.x | next.y) & 0xC000 != 0` post-step and applies the two-gate removal via `Simulation.Units.untargetUnit` + `host.units.free(at:)`. Bounce branch is a position-hold stub (no SAVE007 path hits it).
- `Code/Core/Sources/DuneIICore/Simulation/ParityHarness.swift:compareHouse` — `unitCount` is now in the diff schema; the port is what unblocked it.

## Where it lives in the reference

- `Repositories/OpenDUNE/src/unit.c:1305..1317` — the two-gate branch inside `Unit_Move`.
- `Repositories/OpenDUNE/src/unit.c:897..914` — `Unit_Remove` itself: `Unit_UntargetMe`, `Unit_UpdateMap(0, u)`, `Unit_HouseUnitCount_Remove`, `Script_Reset`, `Unit_Free`. Swift's port skips `Unit_UpdateMap(0)` (fog-of-war layer not modelled) and `Script_Reset` (implicit via `isUsed = false`).
- `Repositories/OpenDUNE/src/tile.h:14` — `Tile_IsValid` macro.
- `Repositories/OpenDUNE/src/table/unitinfo.c` — rows 0 and 1 carry `mustStayInMap = true`; all others are `false`.
