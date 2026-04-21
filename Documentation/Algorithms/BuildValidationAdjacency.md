# Build validation — HP degradation + adjacent-to-base gate (slice 4c)

Status: Drafted 2026-04-21 (P5 slice 4c — third and final validation pass).

Slice 4b returned `-neededSlabs` as the validity value but treated any non-zero as success. Slice 4c closes two remaining gaps in `Structure_IsValidBuildLocation` + `Structure_Place`:

1. **HP degradation on placement** — if `n` of a structure's footprint tiles lack concrete underneath, spawn with `hitpoints = hitpointsMax - (hitpointsMax / 2) * n / footprintCount`. Set the `degrades` flag so the (future) degradation tick knows to decay HP further.
2. **Adjacent-to-player-base gate** — non-CY player placements must have at least one of 16 surrounding tiles containing a player-owned structure, concrete slab, or wall. Prevents the player from plopping a windtrap in the map corner far from their base.

Together these complete the match with OpenDUNE's `Structure_IsValidBuildLocation` + `Structure_Place` HP math. Only the live-landscape-update on placement stays deferred (see §5) — that's a rendering concern.

References:

- `src/structure.c:Structure_IsValidBuildLocation` — lines after the main footprint loop.
- `src/structure.c:Structure_Place` — the `validBuildLocation < 0` branch doing HP damage.
- `src/table/structureinfo.c:g_table_structure_layoutTilesAround` — 7-layout × 16-offset adjacency table.

## 1. HP degradation

OpenDUNE:

```c
if (validBuildLocation < 0) {
    uint16 tilesWithoutSlab = -(int16)validBuildLocation;
    uint16 structureTileCount = g_table_structure_layoutTileCount[si->layout];
    s->o.hitpoints -= (si->o.hitpoints / 2) * tilesWithoutSlab / structureTileCount;
    s->o.flags.s.degrades = true;
}
```

Swift port: `Structures.create(..., tilesWithoutSlab: Int = 0)`. Uses C's integer-arithmetic order `(hitpointsMax / 2) * tilesWithoutSlab / footprintCount` — integer division of the half-max first, then multiply, then divide. For a 2×2 windtrap (hp=200, footprint=4) with all 4 tiles lacking slab:

- damage = (200 / 2) * 4 / 4 = 100
- hitpoints = 200 - 100 = 100

Half HP on unsupported concrete-free placement. Caller (`ScenarioScene.commitPlacement`) passes `-validity` when the `isValidBuildLocation` result is negative.

New `StructureSlot.degrades: Bool` field (default false; plumbed from save's `ObjectFlags.degrades` bit). Set true on degraded placements. No per-tick decay yet — that's slice 4d / 5.

## 2. Layout tiles-around table

Port of `g_table_structure_layoutTilesAround`. The C table uses packed-tile offsets (`-64` = north, `+1` = east, etc.); we decompose to `(dx, dy)` pairs for readability. 7 rows of 8 to 16 entries (trailing zeros in C are terminator sentinels — we just don't emit them).

Exposed as `StructureLayout.adjacentOffsets: [(x: Int, y: Int)]`.

Row summary (`(dx, dy)` relative to anchor):

- **s1x1** (8 entries): standard 8-neighbourhood around (0,0).
- **s2x1** (10): ring around the 2×1 footprint.
- **s1x2** (10): ring around the 1×2 footprint.
- **s2x2** (12): ring around the 2×2 footprint.
- **s2x3** / **s3x2** (14 each).
- **s3x3** (16).

Specifically, for s3x3: north edge (0..2 at y=-1), east edge (3 at y=0..2), south edge (0..2 at y=3), west edge (-1 at y=0..2), plus four corners. Matches OpenDUNE's clockwise-from-NW walk.

## 3. Adjacency gate

OpenDUNE:

```c
if (g_validateStrictIfZero == 0 && isValid && type != STRUCTURE_CONSTRUCTION_YARD && !g_debugScenario) {
    isValid = false;
    for (i = 0; i < 16; i++) {
        uint16 offset = g_table_structure_layoutTilesAround[si->layout][i];
        if (offset == 0) break;
        uint16 curPos = position + offset;
        Structure *s = Structure_Get_ByPackedTile(curPos);
        if (s != NULL) {
            if (s->o.houseID != g_playerHouseID) continue;
            isValid = true; break;
        }
        uint16 lst = Map_GetLandscapeType(curPos);
        if (lst != LST_CONCRETE_SLAB && lst != LST_WALL) continue;
        if (g_map[curPos].houseID != g_playerHouseID) continue;
        isValid = true; break;
    }
}
```

Swift port (inside `isValidBuildLocation`, after the footprint loop):

```swift
if let playerHouseID,
   type != 8 /* CYARD */,
   let landscapeAt  // needed for the slab/wall landscape fallback
{
    var adjacencyOK = false
    for (dx, dy) in info.layout.adjacentOffsets {
        let nx = tileX + dx, ny = tileY + dy
        guard (0..<64).contains(nx), (0..<64).contains(ny) else { continue }

        // Player-owned structure at that tile?
        if let owner = structureOwnerAt(pool: structures, tileX: nx, tileY: ny),
           owner == playerHouseID {
            adjacencyOK = true; break
        }

        // Player-owned concrete slab or wall?
        let lst = landscapeAt(nx, ny)
        if (lst == .concreteSlab || lst == .wall),
           let tileHouseIDAt, tileHouseIDAt(nx, ny) == playerHouseID {
            adjacencyOK = true; break
        }
    }
    if !adjacencyOK { return 0 }
}
```

New helper `structureOwnerAt(pool:tileX:tileY:)` walks `findArray` and returns the first pool entry whose footprint includes the tile (or nil). Private helper on `Simulation.Structures`.

Note the `landscapeAt != nil` guard: the adjacency check needs the landscape closure for the slab/wall fallback. If a caller passes only the pool + no terrain closure, we skip adjacency too (previous-slice parity).

`tileHouseIDAt` is separately optional: when nil, the slab/wall fallback always fails and only the pool-structure check contributes to adjacency. This is the expected state for our scenario-load path (tileGrid `houseID` is 0 everywhere at scenario spawn).

## 4. Signature additions

```swift
public static func isValidBuildLocation(
    tileX: Int, tileY: Int,
    type: UInt8,
    structures: StructurePool,
    units: UnitPool,
    landscapeAt: ((Int, Int) -> LandscapeType)? = nil,
    playerHouseID: UInt8? = nil,
    tileHouseIDAt: ((Int, Int) -> UInt8)? = nil
) -> Int16

public static func create(
    type: UInt8,
    houseID: UInt8,
    position: Pos32,
    pool: inout StructurePool,
    tilesWithoutSlab: Int = 0
) -> Int?
```

All new parameters default to neutral values so slice-4a / 4b tests don't need updates.

## 5. What slice 4c does NOT cover

- **Per-tick HP decay for degraded structures** — slice 4d/5. `degrades` is set but nothing consumes it yet.
- **Live landscape updates on placement** — stamping `LST_STRUCTURE` / `LST_CONCRETE_SLAB` onto footprint tiles as the player builds. Means: once the player builds a slab, the landscape gate still sees the tile as rock/sand underneath. The pool check is authoritative for structure overlap; for adjacency, structures in the pool already count.
- **`g_validateStrictIfZero`** — OpenDUNE's scenario-init scratch flag. Always treated as 0 (strict validation) by our port; the scenario loader doesn't route through this function anyway.
- **`g_debugScenario`** — always treated as false.

## 6. Testing

Extend `BuildValidationTests`:

### HP degradation

- `Structures.create(tilesWithoutSlab: 0)` → hitpoints == hitpointsMax, degrades == false (slice-2 semantics, explicit baseline).
- `create(type: WINDTRAP, tilesWithoutSlab: 4)` → hitpoints == 100 (half), degrades == true.
- `create(type: WINDTRAP, tilesWithoutSlab: 2)` → hitpoints == 150 (75% — `(200/2) * 2 / 4 = 50` damage).
- `create(type: REFINERY, tilesWithoutSlab: 6)` → hitpoints == 225 (`(450/2) * 6 / 6 = 225` damage).

### Adjacency

- Pool empty, landscape all sand, playerHouseID=ATR, try to build WINDTRAP at (5, 5) → invalid (no adjacent base).
- Pool has player-owned WINDTRAP at (5, 5); try to build REFINERY at (7, 5) (2 tiles east — adjacent) → valid.
- Same pool; try REFINERY at (10, 10) (not adjacent) → invalid.
- Enemy-owned structure adjacent → adjacency check fails (`owner != playerHouseID`).
- CYARD placement never runs adjacency check (valid as long as bounds + landscape + overlap pass).
- `playerHouseID = nil` preserves 4b semantics (no adjacency check).

### `layoutTilesAround` table

- s1x1 has exactly 8 entries covering the 8-neighbourhood.
- s3x3 has exactly 16 entries forming the ring at distance 1 from the 3×3 footprint.

## 7. Scene wiring

`ScenarioScene.commitPlacement` already has `playerHouseID` + `tileGrid` + `landscapeAt`. Add:

```swift
let tileHouseIDAt: (Int, Int) -> UInt8 = { x, y in
    guard (0..<64).contains(x), (0..<64).contains(y) else { return 0 }
    return tiles[y * 64 + x].houseID
}
```

Pass `playerHouseID` + `tileHouseIDAt` to `isValidBuildLocation`. When the call returns `-n`, also pass `tilesWithoutSlab: n` to `Structures.create` so the HP degradation lands.

WorldSnapshot plumbing: copy `ObjectFlags.degrades` into the new `StructureSlot.degrades` in the save init path. Scenario-spawn path leaves it false (scenarios don't mark structures degraded).

## 8. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/StructurePool.swift` — `StructureSlot.degrades: Bool`.
- `Code/Core/Sources/DuneIICore/Simulation/StructureInfo.swift` — `StructureLayout.adjacentOffsets`.
- `Code/Core/Sources/DuneIICore/Simulation/Structures.swift` — extended signatures + adjacency + HP math.
- `Code/Core/Sources/DuneIICore/Simulation/WorldSnapshot.swift` — plumb `degrades` flag from save.
- `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — wire closures + tilesWithoutSlab.
- `Code/Core/Tests/DuneIICoreTests/BuildValidationTests.swift` — extended suite.
- `Code/Core/Tests/DuneIICoreTests/StructureCreateTests.swift` — HP degradation tests.
