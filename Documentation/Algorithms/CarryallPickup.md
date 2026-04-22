# Carryall pickup loop (spice income slice 8)

Problem: today's `Scheduler.tickHarvesting` routes every full harvester to the single nearest refinery via `findNearestRefinery`, regardless of whether it already has a docked harvester. With two refineries + two harvesters, both harvesters queue at the closer refinery while the other sits idle. In OpenDUNE this ferry is handled by a carryall that picks up full harvesters and flies them to a free refinery.

Scope: port enough of OpenDUNE's `Unit_CallUnitByType` + `Script_Unit_CallUnitByType` + `Unit_FindClosestRefinery` to restore the "parallel refinery utilisation" loop. Breaking into three atomic slices so each one ships independently with its own tests + history bullet.

## OpenDUNE reference

- `src/unit.c:784..840` — `Unit_FindClosestRefinery`: two-pass search. First pass prefers refineries with `state == STRUCTURE_STATE_BUSY` (actively operational); second pass falls back to any refinery of the same house. Writes `unit->originEncoded` to the winning refinery's encoded index.
- `src/unit.c:2131..` — `Unit_CallUnitByType`: finds an existing idle carryall (or spawns one if `createCarryall`), sets its `targetMove` to an encoded target, and links the caller via `Object_Script_Variable4_Link`.
- `src/unit.c:1780..1830` — unnamed winger wrapper: spawns a carryall at the map edge, links a freshly-created passenger via `linkedID` + `flags.inTransport`, routes carryall to destination.
- `src/script/unit.c:1500..` — `Script_Unit_CallUnitByType`: EMC entrypoint called from a harvester's UNIT.EMC when it needs a ferry.

## Slice breakdown

### 8a — pure-sim `findFreeRefinery` + tickHarvesting preference

**Goal:** a full harvester prefers a refinery with no docked harvester (`linkedID == 0xFF`) over the absolute nearest. Falls back to `findNearestRefinery` when every refinery already has a docked harvester.

**Changes:**
- `Simulation.Structures.findFreeRefinery(forHouse:position:pool:) -> Int?` — walks the structure findArray, returns the nearest refinery of `houseID` whose `linkedID == 0xFF`. Nil when every refinery is chain-linked. Pure — takes a `Pos32` anchor, reads pool state, no mutation.
- `Scheduler.tickHarvesting` — full-harvester branch tries `findFreeRefinery` first, falls back to the existing `findNearestRefinery`. Logs `target=free` vs `target=busy-fallback` under the `harvest-tick` tracer so traces make the decision visible.

**Observable:** run mission 1, build two refineries → two harvesters. Each takes turns docking at a different refinery instead of both queueing at the nearest. Tests cover the pure helper + a synthetic two-refinery scenario where one is chain-linked and the other is empty.

**Not yet shipped:** actual carryall. Slice 8a just picks a better destination — if all refineries are busy or there's no free one, the fallback still queues behind the nearest.

### 8b — carryall spawn + harvester link

**Goal:** when a full harvester arrives at its target refinery and finds it busy (or when the target isn't reachable cheaply), spawn a carryall at a map-edge tile, link the harvester via `linkedID` + `flags.inTransport`, route the carryall to the free refinery.

**Changes:**
- `Simulation.Units.callCarryall(forHarvester:destination:units:)` — ports the carryall-creation tail of `Unit_CallUnitByType`: allocates a CARRYALL slot, writes `targetMove = encoded(refinery)`, `inTransport = true`, `linkedID = harvester.index`, spawns at a house-chosen map-edge tile (use `Map_FindLocationTile` equivalent or just the corner nearest to the house CY).
- `Scheduler.tickHarvesting` — when a full harvester is standing at the busy refinery (or the chain-queue has grown past a threshold), call the carryall helper instead of re-routing on foot.
- `Simulation.Units.createUnit` — audit for CARRYALL type handling (bypass passability, winger movement; already handled by `MovementType.winger`, re-confirm).

### 8c — carryall flight + drop-off + re-dock

**Goal:** carryall arrives at the destination refinery; drop the harvester on a passable adjacent tile; unlink; carryall flies off. Harvester's next `tickHarvesting` pass picks it up in RETURN action and docks.

**Changes:**
- `Scheduler.tickMovement` or `tickCarryall` — when an inTransport carryall reaches its targetMove (refinery anchor), invoke `Simulation.Units.dropCarried(carryallIndex:units:structures:)`:
  - Unlink (`linkedID = 0xFF`, `inTransport = false`).
  - Place the harvester at the first passable tile adjacent to the destination refinery.
  - Reset carryall to a return-to-origin move (optional — can also free the slot or send it home).
- Harvester flips to `RETURN` so the next tick docks via the existing flow.

## Test plan

| Slice | Tests |
|---|---|
| 8a | `findFreeRefinery` returns nil when pool empty / no refinery matches house / every refinery busy. Picks the nearest of two free refineries. Falls back to busy refinery in scheduler when no free candidate. |
| 8b | `callCarryall` allocates a CARRYALL slot with `inTransport=true`, `linkedID=harvester`, `targetMove=encoded(refinery)`. Honours CARRYALL pool range 0..5. |
| 8c | Carryall arriving at destination triggers `dropCarried`. Harvester's position snaps to a passable neighbour; `inTransport` clears on both sides. |

Install-gated integration test: run the scheduler N ticks with two refineries + two harvesters, assert that each refinery docks at least one harvester within a generous tick budget.

## Manual verification

After slice 8c: `swift run duneii` → build 2nd refinery → 2nd harvester → watch carryall spawn and ferry. No crash on first flight. Traces show `harvest-tick` + `carryall` entries in order.
