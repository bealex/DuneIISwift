# `Structure_Create` (+ `Structure_Allocate` + minimal `Structure_Place`)

Status: Drafted 2026-04-21 (P5 kickoff — slice 2: structure allocation).

`Structure_Create` is the allocator that spawns a new structure of a given type at a given tile for a given house. It's what a construction yard calls when the player commits a placement after construction completes, and what scenario loaders call to place starting structures. OpenDUNE: `src/structure.c:Structure_Create` → `src/pool/structure.c:Structure_Allocate` → `src/structure.c:Structure_Place`.

This slice ports only the **normal-building** path (non-slab / non-wall). Slab / wall placement, script reset, fog uncovering, power recalc, factory queue setup, and the AI auto-upgrade loop are listed in §6 as deferred. Slice 2 is a thin seam that lets a later slice wire clicks from the build panel without tangling in state-machine details.

References:

- `src/structure.c:Structure_Create` — top-level constructor.
- `src/pool/structure.c:Structure_Allocate` — pool slot assignment (soft range `[0, 79)` for normal structures; reserved 79/80/81 for walls/slabs/slabs).
- `src/structure.c:Structure_Place` — positions the allocated structure on the map. We port only the non-slab / non-wall tail.
- `src/structure.h:STRUCTURE_STATE_*` — state enum: `DETECT=-2`, `JUSTBUILT=-1`, `IDLE=0`, `BUSY=1`, `READY=2`.

## 1. New fields on `StructureSlot`

Three fields we haven't plumbed yet (all three already exist on the save record in `Formats.Save.Structures.Slot`, so round-trip is free):

- `hitpointsMax: UInt16` — seeded on create from `StructureInfo.hitpoints`; damage reduces `hitpoints` without touching this.
- `upgradeLevel: UInt8` — initially `0`; Harkonnen LIGHT_VEHICLE yards special-case to `1` (see §4). Used by `Structure_GetBuildable` (slice 1) + factory upgrades (deferred).
- `objectType: UInt16` — what this factory is currently producing; `0xFFFF` = nothing. Seeded to `0xFFFF` on create. Not actively read by slice 2; seeded so slice 4 (queue) can write it.

All three get plumbed through both `WorldSnapshot.init` paths (save + scenario), matching the pattern used for `state` / `countDown` in the previous slice. `StructureSlot` keeps its `Sendable, Equatable` conformance.

## 2. `Simulation.Structures.allocate(at:type:houseID:pool:)`

Port of `Structure_Allocate` (`src/pool/structure.c`). Returns a concrete pool index or `nil`.

```
inputs: requestedIndex (u16; 0xFFFF = find first free), type, houseID
outputs: pool index (Int) or nil

if type in {SLAB_1x1}: return allocateReserved(at: indexSlab1x1, type)
if type in {SLAB_2x2}: return allocateReserved(at: indexSlab2x2, type)
if type in {WALL}:     return allocateReserved(at: indexWall, type)

if requestedIndex == 0xFFFF:
    for i in 0..<capacitySoft:
        if !pool.slots[i].isUsed:
            return pool.allocate(at: i, type, houseID)
    return nil          # no free slot
else:
    if pool.slots[requestedIndex].isUsed: return nil
    return pool.allocate(at: Int(requestedIndex), type, houseID)
```

OpenDUNE's `Structure_Allocate` also `memset`s the entire struct to zero and sets `used` / `allocated` / `linkedID = 0xFF` / `script.delay = 0`. Our `StructurePool.allocate(at:type:houseID:)` already emits a fresh `StructureSlot(...)` with those defaults, so the pool-level primitive is already equivalent. The sim-level wrapper only adds the allocator-range logic.

The scenario-spawn path in `WorldSnapshot.init(scenario:)` continues to use `StructurePool.allocate(at:type:houseID:)` directly (it already knows the index). `Structures.allocate` is what the build-panel UI (and AI) will call when they don't have a specific index in mind.

## 3. `Simulation.Structures.create(type:houseID:position:host:)`

Port of `Structure_Create` (non-slab / non-wall tail of `Structure_Place`). Returns the allocated slot index, or `nil` if the type / house / pool cannot satisfy the request.

```
inputs: type, houseID, position (Pos32 centred at tile anchor), host
outputs: pool index or nil

if houseID >= 6: return nil
if type >= 19: return nil

idx = allocate(at: 0xFFFF, type, houseID, pool: &host.structures)
if idx == nil: return nil

info = StructureInfo.table[type]
slot = host.structures[idx]

# §4: per-house / per-type seed
slot.state               = STRUCTURE_STATE_JUSTBUILT  (= -1)
slot.linkedID            = 0xFF   (redundant — pool.allocate already sets this)
slot.hitpoints           = info.hitpoints
slot.hitpointsMax        = info.hitpoints
slot.objectType          = 0xFFFF
slot.countDown           = 0
slot.upgradeLevel        = 0

if houseID == HOUSE_HARKONNEN && type == LIGHT_VEHICLE:
    slot.upgradeLevel = 1

# §5: place — non-slab / non-wall only
slot.positionX = position.x & 0xFF00  # align to tile
slot.positionY = position.y & 0xFF00

host.structures[idx] = slot
return idx
```

OpenDUNE also calls `Structure_BuildObject(s, 0xFFFE)` which sets up `s->objectType` and the build cost / countdown for the initial production item. For slice 2 we leave `objectType = 0xFFFF`; slice 4 (queue ingest) ports `Structure_BuildObject`.

## 4. Harkonnen LIGHT_VEHICLE upgradeLevel exception

OpenDUNE line in `Structure_Create`:

```c
if (houseID == HOUSE_HARKONNEN && typeID == STRUCTURE_LIGHT_VEHICLE) {
    s->upgradeLevel = 1;
}
```

Harkonnen start their light-vehicle factory at upgrade level 1 — rationale in the community is that HK never needs (and can never build) a barracks, so their LV factory skips the mid-tier to get at the Heavy pathway. This is load-bearing if the campaign later unlocks upgradeable HK-LV buildables. We preserve it.

## 5. AI auto-upgrade loop (deferred)

OpenDUNE's `Structure_Create` tail:

```c
if (houseID != g_playerHouseID) {
    while (true) {
        if (!Structure_IsUpgradable(s)) break;
        s->upgradeLevel++;
    }
    s->upgradeTimeLeft = 0;
}
```

This pushes every AI structure to its max campaign-gated upgrade level on creation, so AI factories produce the highest-tier units they have access to. Deferred to slice 2b (or whenever we need AI production parity): requires porting `Structure_IsUpgradable`, which looks at per-type `upgradeCampaign[3]`, `g_campaignID`, structural prereqs, and the HK-WOR edge case.

This means AI structures created by slice 2 will start at `upgradeLevel = 0` — functionally equivalent to the player path. AI scenario structures loaded from the save path keep whatever `upgradeLevel` the save recorded, which is what OpenDUNE's save files already reflect post-auto-upgrade. So the save round-trip is still correct; only the "AI spawns a new structure mid-game" path is degraded, which isn't reachable in slice 2.

## 6. What slice 2 does NOT cover

- **Slab / wall `Structure_Place`** — stamps map tiles, frees the pool slot, connects walls. Separate logic branch; defer until the player can queue walls or slabs (needs slice 4).
- **`Structure_BuildObject(s, 0xFFFE)`** — factory's initial production queue seed. Defer to slice 4 (queue ingest).
- **`Structure_IsUpgradable`** — complex gate logic. Deferred; AI auto-upgrade loop also deferred.
- **Factory `upgradeTimeLeft = 100`** — only needed once AI upgrade is on. Deferred.
- **Turret `rotationSpriteDiff` seeding via `g_iconMap`** — cosmetic. Turrets spawn facing N (rotationSpriteDiff = 0) until slice 5.
- **Fog uncovering** — `Tile_RemoveFogInRadius(..., radius)`. Deferred.
- **`s.seenByHouses` stamping** — OpenDUNE ORs `1 << houseID` (and `0xFF` for player). Deferred; scenario-spawned structures already get `0xFF` from an earlier slice.
- **`Structure_IsValidBuildLocation`** — the placement validator. Deferred to slice 4 (cursor commit). Slice 2 takes any `Pos32` the caller provides.
- **Unit removal at target tile** — if a unit sits on the target, OpenDUNE calls `Unit_Remove`. Deferred.
- **Power / credits recalc** — `House_CalculatePowerAndCredit` deferred to slice 5 (HUD + economy).
- **Windtrap count increment** — pure cache; recomputed lazily via `structuresBuilt`. Deferred.
- **Script reset + load** — `Script_Reset(&s->o.script, g_scriptStructure)` + `Script_Load`. Done elsewhere: `ScenarioScene.setUpScheduler` already loads `BUILD.EMC` + wires the structure VM, so new structures participate on the next scheduler tick automatically. Slice 2's structure has `state = JUSTBUILT` and a fresh engine-state hash; the scheduler allocates an engine per slot on first access.
- **Construction countdown state machine** — ticking `countDown` on BUSY yards, flipping to READY at zero. Deferred to slice 2b. Slice 2 leaves `countDown = 0`.

## 7. Testing

Pure sim + single-side-effect-on-pool function. New `Tests/DuneIICoreTests/StructureCreateTests.swift`:

- `allocate` returns a slot in `0..<79` for the first normal-structure alloc on an empty pool.
- `allocate` routes SLAB_1x1 / SLAB_2x2 / WALL to the reserved indices 81 / 80 / 79 respectively.
- `allocate` with an explicit in-range index uses that index; returns nil if the slot is taken.
- `allocate` with `0xFFFF` on a pool where slots 0..39 are filled returns index 40.
- `allocate` returns nil when every slot 0..<79 is in use.
- `create` rejects houseID ≥ 6.
- `create` rejects type ≥ 19.
- `create` seeds `state = STRUCTURE_STATE_JUSTBUILT` (-1), `hitpoints = hitpointsMax = StructureInfo.table[type].hitpoints`, `linkedID = 0xFF`, `objectType = 0xFFFF`, `countDown = 0`, `upgradeLevel = 0`.
- `create` for Harkonnen + LIGHT_VEHICLE seeds `upgradeLevel = 1`.
- `create` aligns `positionX` / `positionY` to tile boundary (`& 0xFF00`).
- `create` on a full pool returns nil.
- `create` registers the slot in `findArray` (observable via `PoolQuery`).
- `WorldSnapshot` save round-trip preserves `hitpointsMax` / `upgradeLevel` / `objectType` (integration test against `_SAVE001.DAT`).

## 8. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/Structures.swift` — `allocate` + `create` live alongside the existing `structuresBuilt` / `buildableStructuresFromYard` from slice 1.
- `Code/Core/Sources/DuneIICore/Simulation/StructurePool.swift` — unchanged; the existing `allocate(at:type:houseID:)` is the pool-level primitive.
- `Code/Core/Sources/DuneIICore/Simulation/WorldSnapshot.swift` — both init paths gain `hitpointsMax` / `upgradeLevel` / `objectType` assignments.
