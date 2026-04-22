# Harvester → refinery spice deposit (refine step)

First slice of the P4→P5 economy bridge. Ports the per-tick deposit math in OpenDUNE's `Script_Structure_RefineSpice` (`src/script/structure.c:105..153`) as a pure-sim function. No script wiring, no AI loop, no spice-tile mutation — those land in follow-up slices.

## What OpenDUNE does

`Script_Structure_RefineSpice` is the structure script slot a docked refinery runs every 6 ticks while it has a linked harvester (`s->o.linkedID`). Each call either:

1. Drains `harvesterStep` spice from `u->amount`, credits the refinery's owner `creditsStep × harvesterStep`, or
2. Clears the harvester's `inTransport` and returns when `u->amount == 0`.

Formula (from lines 140..149):

```c
harvesterStep = (s->hitpoints * 256 / si->hitpoints) * 3 / 256;
if (harvesterStep > u->amount) harvesterStep = u->amount;

creditsStep = 7;
if (u->o.houseID != g_playerHouseID) {
    creditsStep += (Tools_Random_256() % 4) - 1;   // -1 .. +2 jitter
}
creditsStep *= harvesterStep;
h->credits += creditsStep;
u->amount -= harvesterStep;
```

- `harvesterStep` is the per-tick ore drain, capped by how much the harvester still carries and scaled by the refinery's HP ratio. A fully-healthy refinery deposits **3 spice/tick**; at 33% HP it deposits 1/tick; below 33% it deposits 0 until repaired.
- `creditsStep` is spice → credits conversion. Player harvesters always convert at exactly 7. Enemy harvesters get −1..+2 jitter drawn from `Tools_Random_256`.

Zero side-effects on refinery state — it stays READY throughout (`busyStateIsIncoming = true`). The harvester stays linked; unlink happens elsewhere via `Script_Structure_FindAndLeaveUnit`.

See the scoping report in this commit's history for file:line confirmations.

## Swift port — pure sim

```swift
// Simulation.Structures
@discardableResult
public static func refineSpiceStep(
    refineryIndex: Int,
    harvesterIndex: Int,
    structures: StructurePool,
    units: inout UnitPool,
    houses: inout HousePool,
    playerHouseID: UInt8,
    enemyJitterByte: (() -> UInt8)? = nil
) -> UInt16
```

Returns the credits gained this step (0 when the step is a no-op or drain-to-zero with nothing left). Implements the formula literally:

1. Validate range/type/allocation: refinery slot is REFINERY (type 12), harvester slot is HARVESTER (type 16), both `isUsed && isAllocated`, both owned by the same house. Reject to 0.
2. If `harvester.amount == 0`, clear `harvester.inTransport`, return 0.
3. `maxStepByHP = Int(refinery.hitpoints) * 256 / max(1, Int(StructureInfo.refinery.hitpoints)) * 3 / 256` (integer division throughout, same as C).
4. `harvesterStep = min(UInt16(maxStepByHP), harvester.amount)` — possibly 0 at very low refinery HP.
5. `creditsStep = 7`. If `harvester.houseID != playerHouseID` and `enemyJitterByte != nil`, add `Int(byte % 4) - 1` (so jitter range is −1..+2).
6. `gained = creditsStep × harvesterStep`. Clamp `house.credits += gained` into `UInt16` saturation.
7. `harvester.amount -= UInt8(harvesterStep)`. If that reaches 0, clear `harvester.inTransport`.

### Deviations from OpenDUNE

- We do not spawn the `SCRIPT_TEXT` per-step string or play the CREDIT_SFX voice — pure-sim.
- We do not read the refinery's linked harvester through `s->o.linkedID`; the caller passes both indices explicitly. Linkage management belongs to a later slice that wires the dock/undock AI.
- The enemy jitter closure is optional; passing `nil` makes every harvester convert at exactly 7. This is appropriate for mission-1 scope (only the player owns a harvester) and gives tests a determinism knob.
- Credits saturate at `UInt16.max` rather than wrapping. OpenDUNE has no overflow guard — a `UInt32` house credits field — but our `HouseSlot.credits` is `UInt16` and we prefer saturation to wrap.

## Slice 3 — harvest step on a spice tile (shipped 2026-04-21)

`Simulation.Units.harvestSpiceStep(harvesterIndex:units:landscapeAt:changeSpice:rng:) -> UInt16` ports `Script_Unit_Harvest` (`src/script/unit.c:1640..1669`) as a pure function:

1. Gate: must be a live harvester slot with `amount < 100`, standing on a `LandscapeType.spice` or `.thickSpice` tile.
2. `amount += rng() & 1` (adds 0 or 1 per call).
3. `inTransport = true`, `amount` clamped to 100.
4. `(rng() & 0x1F) != 0` — skip drain, return 1 (common path, ~31/32 of calls).
5. Otherwise call `changeSpice(packed, -1)` and return 0 (drain tick, ~1/32).

The map grid lives outside the simulation pools, so tile storage is injected via closures (`landscapeAt`, `changeSpice`). The RNG closure abstracts `Tools_Random_256` so tests can pin sequences. Every step logs under the `harvest` tracer (`amount=A→B`, `DRAIN -1`, `no-drain gate=N`, rejection reasons).

## Slice 4 — runtime `SpiceMap` (shipped 2026-04-21)

`Simulation.SpiceMap` is a 64×64 value type tracking per-tile spice level as an enum `{notSand, bare, thin, thick}`. Port of `Map_ChangeSpiceAmount` transitions (`src/map.c:771..797`):

- `apply(delta:at:) -> Level` — `delta < 0` drains THICK→THIN→BARE; `delta > 0` adds BARE→THIN→THICK. Gates match C exactly: THICK + positive is no-op; BARE + negative is no-op; notSand inert either way.
- `init(landscapeAt:)` — seeds from an arbitrary `(Int) -> LandscapeType` closure (scene passes `{ resolver.landscapeType(cell) }`; tests pass a stub). `.spice` → thin, `.thickSpice` → thick, sandy/dune → bare, else notSand.
- `landscapeByte(at:)` — bridges to the `UInt8 LandscapeType.rawValue` shape the `harvestSpiceStep` closure expects.

Every transition logs under the `spicemap` tracer (`tile=(x,y) level=A→B delta=±1`). `Map_FixupSpiceEdges` is a rendering concern and stays in the scene layer.

## Slice 5 — scheduler wiring + scene integration (shipped 2026-04-21)

`Scripting.Host` gained `spiceMap: Simulation.SpiceMap?`. `Simulation.Scheduler.init` gained `harvestRNG: (() -> UInt8)?`. New `Scheduler.tickHarvesting()` drives the per-tick loop:

1. Iterate `host.units.findArray`; for each HARVESTER (`type == 16`) in `ACTION_HARVEST` with `inTransport == false`, call `Units.harvestSpiceStep` using `host.spiceMap.landscapeByte` + `host.spiceMap.apply` as the closures.
2. Iterate `host.structures.findArray`; for each REFINERY with `linkedID != 0xFF`, call `Structures.refineSpiceStep` once.
3. Flush the mutated `spiceMap` back onto the host.

Called from `tick()` once every `Scheduler.harvestCadenceTicks` (default 3 — ~250 ms at 12 Hz, rough match for OpenDUNE's script-delay 6 at 30 Hz). Auto-gated off when either `spiceMap` or `harvestRNG` is nil, so existing tests without harvest state stay unaffected.

`ScenarioScene.setUpScheduler` seeds the `SpiceMap` from the snapshot tile grid via `TileResolver.landscapeType`, logs the thick/thin counts under `scene`, and wires `harvestRNG = { source.tools.next() }` sharing the scripting RandomSource's `Tools_Random_256` stream.

Logs: `tickHarvesting` entry summary under `harvest-tick` (counter + harvested + refined-pairs); per-action logs retained on `harvestSpiceStep` / `refineSpiceStep` / `SpiceMap.apply`.

## Slice 6 — harvester AI loop (shipped 2026-04-21)

Two additions inside `Scheduler.tickHarvesting`:

**6a — auto-undock after refine.** Once `refineSpiceStep` drains the harvester's amount to 0 (clears `inTransport`), the refine pass records the refinery/harvester pair; a second loop then runs `Structures.undockHarvester` at the factory-spawn south-of-footprint tile, and flips the harvester's `actionID` back to HARVEST so the next pass can seek spice again. Mirrors what `Script_Structure_FindAndLeaveUnit` does when we wire the refinery EMC; for now the scheduler drives it directly.

**6b — seek refinery when full / dock on arrival.** Pre-pass (before harvest/refine):

- HARVESTER in `actionID == HARVEST` with `amount >= 100` and `!inTransport` — find the nearest same-house REFINERY via `Scheduler.findNearestRefinery` (squared-distance over anchor tiles), issue `Units.orderMove(toward refinery anchor)`, flip `actionID = RETURN`.
- HARVESTER in `actionID == RETURN` and `!inTransport` — test if its current tile is inside a refinery footprint via `Scheduler.refineryAt`; if yes, call `Structures.dockHarvester` and flip `actionID = HARVEST`.

Both emit `harvest-tick` logs (`full harvester=X → refinery=Y`, `arrived harvester=X refinery=Y DOCK`, `released harvester=X action=HARVEST tile=(...)`).

End-to-end, a harvester that starts on spice in HARVEST action will: fill to 100 → seek nearest refinery → dock on arrival → drain to 0 over ~34 scheduler-harvest-passes → undock to south-of-footprint → resume seeking spice on its own. ~700 credits per cycle at a full refinery.

## What this slice does NOT ship

- **Seek spice target selection.** On undock the harvester stays in HARVEST action but without a move target — the harvest pass only runs when the unit is already standing on a spice tile. A later slice needs to scan for the nearest `spice / thickSpice` tile and issue `orderMove`.
- **Movement between waypoints.** Movement is driven by `orderMove` + the existing route-follower; nothing new here. But routing into a 3×2 refinery footprint relies on the existing pathfinder's ability to find a path *onto* a structure tile — untested for this slice. Full-cycle test uses a teleport to simulate arrival.
- **Scene tile repaint** when `SpiceMap.apply` flips a level. Cosmetic.
- **Carryall pickup** when all refineries are busy — slice 7.
- **Carryall pickup path** (refinery busy → carryall returns harvester to spice field).
- **Credit readout animation.** The HUD label updates each tick from `Simulation.House.credits(for:in:)` so the number changes live, but no roll-up SFX.
- **Scheduler wiring.** No script slot calls `refineSpiceStep` yet — callers invoke it directly (tests today; per-tick wiring once harvest AI slice lands).

## Slice 2 — dock / undock primitives (shipped 2026-04-21)

`Simulation.Structures.dockHarvester(refineryIndex:harvesterIndex:structures:units:) -> Bool` ports the allied-unit branch of `Unit_EnterStructure` (`src/unit.c:2177..2225`):

1. Validate pair (REFINERY + HARVESTER, same house, allocated).
2. Chain-link: harvester's `linkedID` captures the refinery's prior head (`0xFF` if first); refinery's `linkedID` becomes the new harvester's index.
3. Harvester `inTransport = true` — this doubles as "hidden while docked" for the scene (OpenDUNE's `isNotOnMap` flag is not ported yet).
4. Refinery state flips to READY (`busyStateIsIncoming = true`).

`Simulation.Structures.undockHarvester(refineryIndex:exitTile:structures:units:) -> Int?` ports the unlink dance in `Script_Structure_FindAndLeaveUnit` (`src/script/structure.c:273..283`):

1. Refinery must have `linkedID != 0xFF`.
2. Refinery.linkedID ← harvester.linkedID (next in chain, or `0xFF`).
3. Harvester.linkedID ← `0xFF`, `inTransport = false`, position ← centered exit tile.
4. If chain empty, refinery.state ← IDLE (matches C's `if (s->o.linkedID == 0xFF) Structure_SetState(STRUCTURE_STATE_IDLE)`).

Every step logs under the `dock` tracer so traces tell the full arrival/release story. Does NOT touch harvester's `actionID` — the caller decides the post-unload behaviour (back to spice, stop, etc.).
