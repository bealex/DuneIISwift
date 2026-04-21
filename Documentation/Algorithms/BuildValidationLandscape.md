# Build validation — landscape gate + slab-prereq count (slice 4b)

Status: Drafted 2026-04-21 (P5 slice 4b — landscape portion of `Structure_IsValidBuildLocation`).

Slice 4a validated bounds + pool overlap. Slice 4b adds the **landscape-type gate**: every tile in the footprint must be a landscape type the structure accepts. For most buildings that means "rock or concrete"; for CONSTRUCTION_YARD it means "rock only" (concrete is disallowed — OpenDUNE quirk).

Slice 4b also counts tiles under the footprint that don't already have concrete underneath — OpenDUNE's "slab prereq". The function returns `-neededSlabs` for "valid but degraded" placements. Slice 4b wires this into `isValidBuildLocation`'s return value but doesn't yet apply the degradation to `hitpoints` — that stays `== hitpointsMax` on create. Slice 4c / 5 adds the HP-degradation path once it becomes visible in the HUD.

Adjacent-to-base (`g_table_structure_layoutTilesAround`) and the construction countdown state machine stay deferred.

References:

- `src/structure.c:Structure_IsValidBuildLocation` — the full function.
- `src/table/landscapeinfo.c:g_table_landscapeInfo` — 15-row landscape table.
- `src/table/structureinfo.c` — `notOnConcrete` flag on each structure entry.

## 1. `isValidForStructure2` on `LandscapeInfo`

New Bool field. OpenDUNE values (from `src/table/landscapeinfo.c`):

| type | name                 | isValidForStructure | **isValidForStructure2** |
|------|----------------------|---------------------|--------------------------|
| 0    | NORMAL_SAND          | false               | false                    |
| 1    | PARTIAL_ROCK         | false               | false                    |
| 2    | ENTIRELY_DUNE        | false               | false                    |
| 3    | PARTIAL_DUNE         | false               | false                    |
| 4    | ENTIRELY_ROCK        | true                | true                     |
| 5    | MOSTLY_ROCK          | true                | true                     |
| 6    | ENTIRELY_MOUNTAIN    | false               | false                    |
| 7    | PARTIAL_MOUNTAIN     | false               | false                    |
| 8    | SPICE                | false               | false                    |
| 9    | THICK_SPICE          | false               | false                    |
| 10   | CONCRETE_SLAB        | **true**            | **false**                |
| 11   | WALL                 | false               | false                    |
| 12   | STRUCTURE            | false               | false                    |
| 13   | DESTROYED_WALL       | true                | true                     |
| 14   | BLOOM_FIELD          | false               | false                    |

Only rock-family tiles satisfy `isValidForStructure2`: the CONSTRUCTION_YARD flag `notOnConcrete=true` means it's the only structure that can't sit on a concrete slab. In practice the player can't build a CYARD via the panel (availableCampaign=99), so this branch is only reachable via the scenario/MCV path.

### Pre-existing mis-ports we fix as part of this slice

Cross-checking against OpenDUNE uncovered four wrong values in our pre-slice-4b `LandscapeInfo.table`:

- `5 MOSTLY_ROCK`: `isValidForStructure` was `false` — should be `true`.
- `13 DESTROYED_WALL`: `isValidForStructure` was `false` — should be `true`.
- `4 ENTIRELY_ROCK`, `5 MOSTLY_ROCK`, `9 THICK_SPICE`: `letUnitWobble` was `false` — should be `true`.

`letUnitWobble` isn't consulted anywhere yet, but the two `isValidForStructure` fixes would have blocked placements on mostly-rock tiles — real behaviour would regress. Fix at the source.

## 2. `notOnConcrete` on `StructureInfo`

Bool flag; only `CONSTRUCTION_YARD (type 8)` has it `true`. Add as a stored field with default `false` and set true in the CYARD row.

## 3. Extended `Structures.isValidBuildLocation` signature

```swift
public static func isValidBuildLocation(
    tileX: Int, tileY: Int,
    type: UInt8,
    structures: StructurePool,
    units: UnitPool,
    landscapeAt: ((Int, Int) -> LandscapeType)? = nil
) -> Int16
```

The `landscapeAt` closure is optional: when `nil`, landscape validation is skipped (equivalent to pre-4b behaviour — tests from slice 4a still exercise the bounds + overlap gates without needing a terrain fixture). When provided, each footprint tile is resolved through it and consulted via the appropriate `isValidForStructure{,2}` bit.

Behaviour with the closure:

```
neededSlabs = 0
for (fx, fy) in footprint:
    bounds check — if fail, return 0
    lst = landscapeAt(fx, fy)
    info = LandscapeInfo.lookup(lst)
    if structureInfo.notOnConcrete:
        if !info.isValidForStructure2: return 0
    else:
        if !info.isValidForStructure: return 0
        if lst != LST_CONCRETE_SLAB: neededSlabs += 1
    pool structure overlap check — if hit, return 0
    unit overlap check — if hit, return 0

if neededSlabs == 0: return 1
return -Int16(neededSlabs)
```

Behaviour *without* the closure (slice 4a callers): skip landscape + slab-count sections, return `0` / `1`. Existing slice-4a tests remain valid.

## 4. Scene wiring

`ScenarioScene.commitPlacement` now builds a closure from `WorldSnapshot.tiles` + `TileResolver`:

```swift
let tiles = snapshot.tiles
let resolver = assets.tileResolver
let landscapeAt: (Int, Int) -> Simulation.LandscapeType = { x, y in
    guard x >= 0, x < 64, y >= 0, y < 64 else { return .entirelyMountain }
    let packed = UInt16(y * 64 + x)
    let cell = tiles[Int(packed)]
    return resolver.landscapeType(
        groundTileID: cell.groundTileID,
        overlayTileID: cell.overlayTileID,
        hasStructure: cell.hasStructure
    )
}
```

Called once per commit; captures tile state at scene build. Tile state doesn't update as structures are placed (the snapshot is frozen), so follow-up placements only see the *baseline* landscape — the pool-overlap check still catches overlap with newly-built structures.

A negative return (valid-but-degraded) is logged with the slab deficit and then treated as success for the `create` call (slice 4b doesn't yet apply HP degradation).

## 5. What slice 4b does NOT cover

- **HP degradation on placement** — return value is plumbed but `Structures.create` still sets `hitpoints = hitpointsMax`. Slice 4c adds the `hitpoints -= (max/2) * tilesWithoutSlab / structureTileCount` math + the `degrades` flag.
- **Adjacent-to-base gate** — `g_table_structure_layoutTilesAround` walk. Slice 4c.
- **Landscape updates from placement** — placing a structure doesn't flip footprint tiles to `LST_STRUCTURE` in the validation closure's view. Means two placements that stomp each other would *only* be caught by the pool overlap check, not by landscape. Acceptable: the pool check is authoritative.
- **`g_debugScenario` branch** — our code doesn't differentiate; we always use the "non-debug" path. No user-visible effect in slice 4b.
- **Construction countdown state machine** — clicking a sidebar slot still commits instantly on map-click. Slice 4c/d.

## 6. Testing

Extend `BuildValidationTests`:

- Landscape closure returns `.normalSand` for every tile → 2×2 windtrap at `(5, 5)` → `0`.
- Closure returns `.entirelyRock` → `1` with slabs needed = 4 (all rock, no concrete underneath). Wait, actually the count = 4 means return is `-4`. Let me re-check. `neededSlabs` counts tiles where `lst != LST_CONCRETE_SLAB`. For a 2×2 on all rock, every tile != concrete → `neededSlabs = 4` → return `-4`. Yeah, `-4`.
- Closure returns `.concreteSlab` → `1` (slabs underneath, `neededSlabs = 0` → return `1`).
- Mixed: 2 concrete + 2 rock → return `-2`.
- Sand with a CYARD → invalid (isValidForStructure2=false for sand).
- Rock with a CYARD → valid (`1`, no slab count since CY ignores the concrete counter).
- Concrete with a CYARD → **invalid** (isValidForStructure2=false for concrete — OpenDUNE quirk).
- Closure = nil → slice-4a behaviour (no landscape check). Existing slice-4a tests still pass; verify explicitly via a new test case that passes nil and gets the same results.

## 7. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/LandscapeInfo.swift` — new field + fixed rows.
- `Code/Core/Sources/DuneIICore/Simulation/StructureInfo.swift` — `notOnConcrete` flag populated for CYARD.
- `Code/Core/Sources/DuneIICore/Simulation/Structures.swift` — extended signature + landscape gate + slab count.
- `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — landscapeAt closure on commit.
- `Code/Core/Tests/DuneIICoreTests/BuildValidationTests.swift` — extended suite.
