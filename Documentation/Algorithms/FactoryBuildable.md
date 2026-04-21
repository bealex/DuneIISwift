# Factory buildable units — `Structure_GetBuildable` factory case (slice 5a)

Status: Drafted 2026-04-21 (P5 slice 5a — pure-sim extension of the buildable logic).

Slice 1 ported the CONSTRUCTION_YARD case of `Structure_GetBuildable`. Slice 5a ports the 5 factory cases: LIGHT_VEHICLE, HEAVY_VEHICLE, HIGH_TECH, WOR_TROOPER, BARRACKS. Each factory walks its `buildableUnits[8]` table and returns a bitmask of UNIT type IDs that pass the per-unit gates (prereq structures + house + upgrade level + a couple of Ordos specialties).

STARPORT's `return -1` sentinel (everything available subject to the `g_starportAvailable` list) is deferred.

References:

- `src/structure.c:Structure_GetBuildable` — factory case, verbatim (lines fetched in the webfetch).
- `src/table/unitinfo.c` — per-unit `availableHouse` / `structuresRequired` / `upgradeLevelRequired`.
- `src/table/structureinfo.c` — per-factory `buildableUnits[8]`.

## 1. New `UnitInfo` fields

Three new fields populated for all 27 unit rows. Source values from `src/table/unitinfo.c`:

- `availableHouse: UInt8` — `1 << houseID` bitmask of who can build this unit.
- `structuresRequired: UInt32` — required-prereq bitmask over the 19 structure types.
- `upgradeLevelRequired: UInt8` — minimum `factoryUpgradeLevel` gate.

Non-combat units (Bullet / Rocket / Frigate / Sandworm / Death Hand) get `availableHouse` values that reflect the source table even though they're never in a factory's `buildableUnits` — the table is populated for completeness.

## 2. New `StructureInfo.buildableUnits[8]`

8-entry `UInt8` array per structure. `0xFF` (alias `UNIT_INVALID`) pads unused slots. Only 5 structures carry non-empty tables:

- `LIGHT_VEHICLE (3)`: `[TRIKE(13), QUAD(15), -, -, -, -, -, -]`
- `HEAVY_VEHICLE (4)`: `[SIEGE_TANK(10), LAUNCHER(7), HARVESTER(16), TANK(9), DEVASTATOR(11), DEVIATOR(8), MCV(17), SONIC_TANK(12)]`
- `HIGH_TECH (5)`: `[CARRYALL(0), ORNITHOPTER(1), -, -, -, -, -, -]`
- `WOR_TROOPER (7)`: `[TROOPER(5), TROOPERS(3), -, -, -, -, -, -]`
- `BARRACKS (10)`: `[SOLDIER(4), INFANTRY(2), -, -, -, -, -, -]`

STARPORT / CY / PALACE / WINDTRAP / REFINERY / REPAIR / WALL / TURRET / ROCKET_TURRET / SILO / OUTPOST / HOUSE_OF_IX / SLAB_1x1 / SLAB_2x2: all 8 entries `UNIT_INVALID`.

Default `0xFF × 8` in the memberwise init so the 14 empty-row structures don't need to spell it out.

## 3. `Simulation.Structures.buildableUnitsFromFactory(...)`

Signature:

```swift
public static func buildableUnitsFromFactory(
    factoryType: UInt8,
    factoryHouseID: UInt8,
    factoryUpgradeLevel: UInt8,
    structuresBuilt: UInt32
) -> UInt32
```

Returns a bitmask over UNIT type IDs. Bits 0..26 can be set; higher bits are unused.

Behaviour (port of `src/structure.c`'s factory case):

```
if factoryType not in {3, 4, 5, 7, 10}: return 0
info = StructureInfo.table[factoryType]
ret = 0
for i in 0..<8:
    var unitType = info.buildableUnits[i]
    if unitType == 0xFF: continue

    # Ordos TRIKE → RAIDER_TRIKE substitution.
    if unitType == 13 (TRIKE) && factoryHouseID == ORDOS:
        unitType = 14  # RAIDER_TRIKE

    ui = UnitInfo.table[unitType]
    var upgradeLevelRequired = ui.upgradeLevelRequired

    # Ordos SIEGE_TANK upgrade relaxation.
    if unitType == 10 (SIEGE_TANK) && factoryHouseID == ORDOS:
        upgradeLevelRequired = max(0, upgradeLevelRequired - 1)

    if (structuresBuilt & ui.structuresRequired) != ui.structuresRequired: continue
    if (ui.availableHouse & (1 << factoryHouseID)) == 0: continue

    if factoryUpgradeLevel >= upgradeLevelRequired:
        ret |= 1 << unitType
    # else the "-1 greyed out" case — deferred, we skip.

return ret
```

The "creatorHouseID" in OpenDUNE is used here; we use `factoryHouseID` (i.e., the current owner, not the historical creator). Divergence only matters for captured factories — for mission-play without captures, these are equal.

For `factoryType == 11 (STARPORT)` we also return 0 for slice 5a. Slice 5b / later ports the `g_starportAvailable` flow.

## 4. Ordos specialties (verbatim)

- **TRIKE → RAIDER_TRIKE substitution** — when a LIGHT_VEHICLE factory is owned by Ordos, the TRIKE slot reads as RAIDER_TRIKE. RAIDER_TRIKE's `availableHouse` includes Ordos; TRIKE's does not. This is how Ordos gets any wheeled unit from a LV factory.
- **SIEGE_TANK upgradeLevelRequired -= 1 for Ordos** — makes Ordos siege tanks reachable at factory upgrade level 2 (default 3). Flavourful buff for the "deception" house.

We port both. No bonus or penalty for other houses.

## 5. What slice 5a does NOT cover

- **STARPORT's `return -1`** — "everything available subject to `g_starportAvailable`". Requires a runtime state field tracking the CHOAM trade queue. Defer.
- **`-1` greyed-out case** for units whose upgradeLevel is one level shy of ready (OpenDUNE sets `ui->o.available = -1` when upgrading would unlock; we just skip).
- **`creatorHouseID` vs `houseID` distinction** — we use current owner. Divergence is only observable after a capture.
- **`g_table_structureInfo[i].o.available` side-effect** — OpenDUNE mutates the table as a side-effect of this function; our port is pure (same design choice as slice 1).
- **Per-factory UI surfacing** — slice 5b wires the sidebar to show units for a selected factory. For slice 5a the function exists but nothing calls it.

## 6. Testing

New `Tests/DuneIICoreTests/FactoryBuildableTests.swift`:

### `UnitInfo` new fields

- Pinned spot checks against the OpenDUNE table (Carryall ALL / NONE / 0; Sandworm FREMEN / NONE / 0; Launcher 59 / NONE / 2; Devastator 57 / IX-bit / 0; Siege Tank ALL / NONE / 3).

### `StructureInfo.buildableUnits`

- LIGHT_VEHICLE = [13, 15, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF].
- HEAVY_VEHICLE = [10, 7, 16, 9, 11, 8, 17, 12] (all 8 slots filled).
- BARRACKS = [4, 2, 0xFF × 6].
- CY / PALACE / WINDTRAP = [0xFF × 8].

### `buildableUnitsFromFactory`

- Atreides LV factory, upgradeLevel=0, no IX: TRIKE present, QUAD absent (upgradeLevelRequired=1).
- Atreides LV factory, upgradeLevel=1: TRIKE and QUAD present.
- Harkonnen LV factory, upgradeLevel=1 (HK pin): no TRIKE (availableHouse excludes HK), QUAD present.
- Ordos LV factory, upgradeLevel=0: RAIDER_TRIKE present (TRIKE substitution), TRIKE NOT in mask (substituted out).
- HV factory no IX, upgradeLevel=0: HARVESTER + TANK present; DEVASTATOR absent (IX prereq unmet); MCV absent (upgradeLevelRequired=1).
- HV factory with IX, upgradeLevel=3, Atreides: DEVASTATOR still absent (availableHouse excludes ATRE); SONIC_TANK present; LAUNCHER absent (availableHouse excludes ORD → wait, ATRE is in LAUNCHER's mask, let me re-check).
  Actually Launcher `availableHouse = MERC|SARD|FREM|ATRE|HARK = 59`. Atreides=2 in 59 → 59 & 2 = 2 ✓. upgradeLevelRequired=2, factoryUpgradeLevel=3 → available.
- HV factory Ordos, upgradeLevel=2 (without Ordos bonus would need 3): SIEGE_TANK is present (Ordos -1 makes requirement 2).
- Non-factory type (e.g., REFINERY) → 0.
- STARPORT → 0 (deferred).

### `StructureInfo.buildableUnits` default empty

- Palace row uses the default (all 0xFF).

## 7. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/UnitInfo.swift` — three new fields + populated 27 rows.
- `Code/Core/Sources/DuneIICore/Simulation/StructureInfo.swift` — new `buildableUnits: [UInt8]` + populated 19 rows.
- `Code/Core/Sources/DuneIICore/Simulation/Structures.swift` — `buildableUnitsFromFactory`.
- `Code/Core/Tests/DuneIICoreTests/FactoryBuildableTests.swift` — new suite.
