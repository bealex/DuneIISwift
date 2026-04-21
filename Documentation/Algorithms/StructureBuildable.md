# Structure buildable list — `Structure_GetBuildable` (construction-yard case) + `Structure_GetStructuresBuilt`

Status: Drafted 2026-04-21 (P5 kickoff — slice 1 of the build panel).

When the player clicks a construction yard, the sidebar panel shows *which structure types are available to build right now*. OpenDUNE computes that set in one pure function: `Structure_GetBuildable(s)` (`src/structure.c:1168`). For a CONSTRUCTION_YARD it walks the 19-entry structure table and returns a `uint32` bitmask of types that pass four gates:

1. **Prerequisites** — every bit in `structuresRequired` must already be in the owner's `structuresBuilt` mask (AI houses skip this gate).
2. **Campaign** — `g_campaignID >= availableCampaign - 1` (mission 1 is `campaignID == 0`).
3. **House** — `availableHouse` bitmask contains `1 << houseID` (e.g. BARRACKS excludes Harkonnen, WOR_TROOPER excludes Atreides).
4. **Upgrade level** — `upgradeLevel >= upgradeLevelRequired` on the yard (AI skips this gate). Only ROCKET_TURRET currently requires an upgrade level > 0.

Plus two quirks we port verbatim:

- **Harkonnen WOR exception** — for HOUSE_HARKONNEN at `campaignID >= 1`, WOR_TROOPER's BARRACKS prerequisite is cleared and its `availableCampaign` is pinned to 2 (so Harkonnen skips straight from BARRACKS-less to WOR).
- **Non-Harkonnen LIGHT_VEHICLE** — every house *except* Harkonnen pins LIGHT_VEHICLE's `availableCampaign` to 2 locally, hiding it at mission 1.

This doc covers the CONSTRUCTION_YARD case only — slice 1 of the P5 build panel. The unit-producing cases (LIGHT_VEHICLE / HEAVY_VEHICLE / HIGH_TECH / WOR_TROOPER / BARRACKS) and STARPORT (`return -1` sentinel) are deferred to a later slice.

References:

- `src/structure.c:Structure_GetBuildable` — the function itself.
- `src/structure.c:Structure_GetStructuresBuilt` — the `structuresBuilt` input.
- `src/table/structureinfo.c:g_table_structureInfo` — the per-type data table.
- `src/structure.h:STRUCTURE_*` — the 19 type IDs.
- `src/house.h:FLAG_HOUSE_*` — the house-mask bit layout.

## 1. New fields on `Simulation.StructureInfo`

Four new per-type fields are required. Source: `src/table/structureinfo.c`.

- `availableCampaign: UInt16` — mission index (1-indexed) where this type unlocks. `99` means never.
- `availableHouse: UInt8` — bitmask `(1 << houseID)`. `FLAG_HOUSE_ALL` is `0b00111111 = 63` (all six houses).
- `structuresRequired: UInt32` — bitmask of `1 << structureType` prerequisites. `FLAG_STRUCTURE_NONE = 0`; `FLAG_STRUCTURE_NEVER = 0x80000000` (used for CONSTRUCTION_YARD — can't be built by anything, you start with it).
- `upgradeLevelRequired: UInt8` — minimum `upgradeLevel` on the yard. Zero for all but `ROCKET_TURRET` (2) and `SLAB_2x2` (1).

Full table (19 entries):

| # | Name              | availCampaign | availableHouse                | structuresRequired                                    | upgLvl |
|---|-------------------|---------------|-------------------------------|-------------------------------------------------------|--------|
| 0 | SLAB_1x1          | 1             | ALL                           | NONE                                                  | 0      |
| 1 | SLAB_2x2          | 4             | ALL                           | NONE                                                  | 1      |
| 2 | PALACE            | 8             | ALL                           | STARPORT                                              | 0      |
| 3 | LIGHT_VEHICLE     | 3             | ALL                           | REFINERY \| WINDTRAP                                  | 0      |
| 4 | HEAVY_VEHICLE     | 4             | ALL                           | OUTPOST \| WINDTRAP \| LIGHT_VEHICLE                  | 0      |
| 5 | HIGH_TECH         | 5             | ALL                           | OUTPOST \| WINDTRAP \| LIGHT_VEHICLE                  | 0      |
| 6 | HOUSE_OF_IX       | 7             | ALL                           | REFINERY \| STARPORT \| WINDTRAP                      | 0      |
| 7 | WOR_TROOPER       | 5             | MERC \| SARD \| FREM \| ORD \| HARK | OUTPOST \| BARRACKS \| WINDTRAP                | 0      |
| 8 | CONSTRUCTION_YARD | 99            | ALL                           | NEVER                                                 | 0      |
| 9 | WINDTRAP          | 1             | ALL                           | NONE                                                  | 0      |
|10 | BARRACKS          | 2             | MERC \| SARD \| FREM \| ORD \| ATRE | OUTPOST \| WINDTRAP                            | 0      |
|11 | STARPORT          | 6             | ALL                           | REFINERY \| WINDTRAP                                  | 0      |
|12 | REFINERY          | 1             | ALL                           | WINDTRAP                                              | 0      |
|13 | REPAIR            | 5             | ALL                           | OUTPOST \| WINDTRAP \| LIGHT_VEHICLE                  | 0      |
|14 | WALL              | 4             | ALL                           | OUTPOST \| WINDTRAP                                   | 0      |
|15 | TURRET            | 5             | ALL                           | OUTPOST \| WINDTRAP                                   | 0      |
|16 | ROCKET_TURRET     | 0             | ALL                           | OUTPOST \| WINDTRAP                                   | 2      |
|17 | SILO              | 2             | ALL                           | REFINERY \| WINDTRAP                                  | 0      |
|18 | OUTPOST           | 2             | ALL                           | WINDTRAP                                              | 0      |

`FLAG_HOUSE_ALL = 0b00111111 = 63`. `BARRACKS` availableHouse is `0b00111110 = 62` (no Harkonnen). `WOR_TROOPER` is `0b00111101 = 61` (no Atreides).

## 2. `Simulation.Structures.structuresBuilt(houseID:pool:)`

Port of `Structure_GetStructuresBuilt` (`src/structure.c`). Pure function over the structure pool:

```
result = 0
for slot in pool.findArray:
    if slot.houseID != houseID: continue
    # isNotOnMap: structures in transit. Not modelled yet; treat all
    # used+allocated pool entries as on-map. See §6.
    if slot.type in {SLAB_1x1, SLAB_2x2, WALL}: continue
    result |= 1 << slot.type
return result
```

Returns a `UInt32` bitmask over structure type IDs 0..18. OpenDUNE also mutates `h->windtrapCount` here as a side effect (recount windtraps); that's a concern for the power-consumption subsystem, not the build panel, so we keep it as a separate helper in a later slice.

Only slots in the pool's `findArray` are visited — reserved aggregate slots 79 / 80 / 81 (walls/slab2x2/slab1x1) are skipped automatically because `allocateReserved` doesn't append to `findArray`.

## 3. `Simulation.Structures.buildableStructuresFromYard(...)`

Port of the `STRUCTURE_CONSTRUCTION_YARD` case of `Structure_GetBuildable` (`src/structure.c`). Pure function; takes the yard's facts + the house's `structuresBuilt` + the campaign ID as arguments. Returns a `UInt32` bitmask:

```
ret = 0
for typeID in 0..<19:
    info = StructureInfo.table[typeID]
    availableCampaign = info.availableCampaign
    structuresRequired = info.structuresRequired

    # Harkonnen WOR exception
    if typeID == WOR_TROOPER && yardHouseID == HARKONNEN && campaignID >= 1:
        structuresRequired &= ~(1 << BARRACKS)
        availableCampaign = 2

    prereqsMet = (structuresBuilt & structuresRequired) == structuresRequired
    isAIYard = (yardHouseID != playerHouseID)

    if !prereqsMet && !isAIYard: continue

    # Non-Harkonnen LIGHT_VEHICLE pin
    if typeID == LIGHT_VEHICLE && yardHouseID != HARKONNEN:
        availableCampaign = 2

    # Campaign gate (unsigned arithmetic: guard against underflow when
    # availableCampaign == 0 like ROCKET_TURRET).
    if !(campaignID >= availableCampaign - 1): continue
    if (info.availableHouse & (1 << yardHouseID)) == 0: continue

    # Upgrade gate — AI yards skip it
    if yardUpgradeLevel >= info.upgradeLevelRequired || isAIYard:
        ret |= 1 << typeID
return ret
```

The function signature exposes every dependency explicitly so tests can pin each gate in isolation:

```swift
static func buildableStructuresFromYard(
    yardHouseID: UInt8,
    yardUpgradeLevel: UInt8,
    structuresBuilt: UInt32,
    campaignID: UInt16,
    playerHouseID: UInt8
) -> UInt32
```

The C campaign gate `g_campaignID >= availableCampaign - 1` promotes both operands to signed `int` before subtracting. So when `availableCampaign == 0` (ROCKET_TURRET) the threshold is `-1` and the gate *passes* for any non-negative campaign — meaning the only thing keeping ROCKET_TURRET gated at player yards is the `upgradeLevelRequired = 2` check further down. The Swift port computes `Int(availableCampaign) - 1` to reproduce that signed-subtract behaviour (naïve `&-` unsigned wrap would gate ROCKET_TURRET out entirely — wrong against OpenDUNE).

The `availableCampaign == 99` sentinel for CONSTRUCTION_YARD does trivially fail the campaign gate — the yard is never "buildable" by another yard, only conquered or mission-started.

## 4. `FLAG_STRUCTURE_NEVER` sentinel

OpenDUNE's `structuresRequired = FLAG_STRUCTURE_NEVER` for CONSTRUCTION_YARD uses `0x80000000`. In practice the CONSTRUCTION_YARD check also fails on `availableCampaign == 99`, so both gates protect it. We model `FLAG_STRUCTURE_NEVER` exactly: `0x80000000`. For a normal house's `structuresBuilt`, bit 31 is never set (only types 0..18 exist), so `(built & required) == required` can never be `true`. Sentinel semantics preserved without a special branch.

## 5. `Simulation.House` bitmask helpers

Add three values to `Simulation.House`:

- `public static let flagAll: UInt8 = 0b00111111` (all 6 houses).
- `public static let flagBarracksHouses: UInt8 = 0b00111110` (all except Harkonnen — BARRACKS).
- `public static let flagWorHouses: UInt8 = 0b00111101` (all except Atreides — WOR_TROOPER).

These are just pre-computed constants for the table rows. A helper `public static func flag(for houseID: UInt8) -> UInt8 { return 1 << houseID }` keeps the callsite tidy.

## 6. What slice 1 does *not* cover

- **`isNotOnMap` filter** — OpenDUNE's `Structure_GetStructuresBuilt` skips structures with `o.flags.isNotOnMap == true`. Our `StructureSlot` doesn't carry that flag. We proxy it as "slot is in the pool's `findArray`", which is equivalent for every currently-modelled scenario (structures never go into transit). If save compat reveals a persisted `isNotOnMap` structure, we'll add the field then.
- **`Structure_IsUpgradable` + upgrade-in-progress** — OpenDUNE's CONSTRUCTION_YARD case also sets `available = -1` (greyed-out) when an upgrade is pending (`upgradeTimeLeft != 0 && upgradeLevel + 1 >= upgradeLevelRequired`). The build-panel UI displays this as a disabled slot. Slice 1 returns only the fully-available bitmask; the `-1` state is deferred.
- **Factory case** (LIGHT_VEHICLE / HEAVY_VEHICLE / HIGH_TECH / WOR_TROOPER / BARRACKS) — porting these needs `UnitInfo.availableHouse / structuresRequired / upgradeLevelRequired` and the per-factory `buildableUnits[8]` table. Deferred to the next slice.
- **Starport case** — returns `-1` (all units available). Deferred with the factory case.
- **`Structure_GetBuildable` side effect** — OpenDUNE *writes* `g_table_structureInfo[i].o.available` as a side effect of this function (`0`, `1`, or `-1`). Our port is pure; the UI derives `available` from the returned bitmask. This is a deliberate design departure (our tables are `let`-static, not mutable globals).
- **UI** — slice 1 is pure sim. Slice 3 wires the bitmask to a `ScenarioScene` sidebar panel.

## 7. Testing

Pure-function port: easy to pin. New `Tests/DuneIICoreTests/StructureBuildableTests.swift` suite covers:

### `structuresBuilt`

- Empty house → 0.
- House with WINDTRAP + REFINERY → `(1 << 9) | (1 << 12) = 0x1200`.
- Same pool, different `houseID` → 0 (doesn't count other houses).
- Skips SLAB_1x1 / SLAB_2x2 / WALL types (type IDs 0 / 1 / 14).

### `buildableStructuresFromYard`

Campaign / house gates (no prereqs):

- **Mission-1 Harkonnen yard, no structures built, as AI (yardHouseID != playerHouseID)** — prereqs skipped, so available set is `{SLAB_1x1, WINDTRAP, REFINERY}` (campaign-1 unlocks); WOR_TROOPER is campaign-5 so still gated out even for Harkonnen-AI.
- **Mission-1 Harkonnen player yard, nothing built** — prereqs enforced, so only `{SLAB_1x1, WINDTRAP}` (REFINERY requires WINDTRAP prereq which isn't built yet).
- **Mission-1 Harkonnen player yard, just a WINDTRAP built** — `{SLAB_1x1, WINDTRAP, REFINERY}`.
- **Atreides player yard, campaign 4, lots built** — should include BARRACKS, should *not* include WOR_TROOPER.
- **Harkonnen player yard, campaign 2, BARRACKS NOT built** — WOR_TROOPER available despite missing BARRACKS (Harkonnen exception).
- **Mission-1 Harkonnen player yard, LIGHT_VEHICLE prereqs met, campaignID = 0** — LIGHT_VEHICLE not in mask (availableCampaign=3, gate fails).
- **Mission-1 Atreides player yard, LIGHT_VEHICLE prereqs met, campaignID = 0** — LIGHT_VEHICLE not in mask (non-Harkonnen pin sets availableCampaign=2; gate fails at campaign 0).
- **Mission-2 Atreides player yard, LIGHT_VEHICLE prereqs met, campaignID = 1** — LIGHT_VEHICLE IS in mask (gate passes at campaign 1).
- **Upgrade gate** — ROCKET_TURRET requires `upgradeLevelRequired = 2`. Player yard with upgradeLevel = 1 and the prereqs + campaign met → NOT in mask. AI yard with same → IS in mask (AI skips upgrade gate).
- **`FLAG_STRUCTURE_NEVER` sanity** — CONSTRUCTION_YARD never in mask regardless of inputs (availableCampaign=99 also guards; both gates present).
- **Player yard's own house never in `availableHouse` of WOR_TROOPER if Atreides** — Atreides can't build WOR_TROOPER at any campaign / prereq combo.
- **Player yard's own house never in `availableHouse` of BARRACKS if Harkonnen** — Harkonnen can't build BARRACKS at any campaign / prereq combo (WOR is the Harkonnen alternative, handled by the WOR exception).

## 8. Integration points landed by slice 1

None. This slice is pure sim: new data on `StructureInfo`, two new pure functions on `Simulation.Structures`, plus tests. No UI. No scheduler. No scene wiring. The follow-up slices layer on.
