# Build validation + `sortPriority` ordering

Status: Drafted 2026-04-21 (P5 slice 4a — placement validity + panel ordering).

Slice 3 lets the player click any tile and stamp a structure there regardless of whether the tile is legal. Slice 4a tightens that: the commit flow now consults a partial port of `Structure_IsValidBuildLocation` (`src/structure.c`) and bails when the target overlaps an existing pool entity or leaves the map. Panel order also swaps from ascending type-ID to `sortPriority` — matching OpenDUNE's factory window.

Slice 4a is deliberately partial. The full port needs landscape-type resolution per tile, plus the "adjacent to player concrete/wall/structure" rule for non-CY buildings. Both arrive in slice 4b. Slice 4a is the narrowest useful validity gate: stop the player stamping one structure on top of another.

References:

- `src/structure.c:Structure_IsValidBuildLocation` — the full function (fetched verbatim; see §5 for what we skip).
- `src/table/structureinfo.c:g_table_structure_layoutTiles` — 7 layouts × up to 9 offsets.
- `src/table/structureinfo.c:g_table_structure_layoutTileCount` — tile-per-layout count.
- `src/table/structureinfo.c:g_table_structureInfo[*].sortPriority` — the panel-ordering field.

## 1. `sortPriority` field on `StructureInfo`

Ported from `src/table/structureinfo.c`. The mapping between `typeID` and `sortPriority`:

| type | name       | sortPriority |
|------|------------|--------------|
| 0    | SLAB_1x1   | 2            |
| 1    | SLAB_2x2   | 4            |
| 2    | PALACE     | 5            |
| 3    | LIGHT_VEHICLE | 14        |
| 4    | HEAVY_VEHICLE | 28        |
| 5    | HIGH_TECH  | 30           |
| 6    | HOUSE_OF_IX | 34          |
| 7    | WOR_TROOPER | 20          |
| 8    | CONSTRUCTION_YARD | 0     |
| 9    | WINDTRAP   | 6            |
| 10   | BARRACKS   | 18           |
| 11   | STARPORT   | 32           |
| 12   | REFINERY   | 8            |
| 13   | REPAIR     | 24           |
| 14   | WALL       | 16           |
| 15   | TURRET     | 22           |
| 16   | ROCKET_TURRET | 26        |
| 17   | SILO       | 12           |
| 18   | OUTPOST    | 10           |

New helper `StructureInfo.buildableTypesByPriority(from mask: UInt32) -> [UInt8]`: decodes the bitmask, sorts ascending by sortPriority. The old `buildableTypes(from:)` stays (ascending type-ID) — scene swaps to the priority variant; tests for the type-ID version remain useful to pin the decomposition separately from the ordering.

## 2. Layout tile offsets

OpenDUNE stores these as packed-tile deltas (`+1` = east, `+64` = south). We work in `(dx, dy)` pairs because our callers already have tile coordinates; the packed form is an implementation detail.

| layout | count | `(dx, dy)` offsets                              |
|--------|-------|-------------------------------------------------|
| s1x1   | 1     | `(0,0)`                                         |
| s2x1   | 2     | `(0,0) (1,0)`                                   |
| s1x2   | 2     | `(0,0) (0,1)`                                   |
| s2x2   | 4     | `(0,0) (1,0) (0,1) (1,1)`                       |
| s2x3   | 6     | `(0,0) (1,0) (0,1) (1,1) (0,2) (1,2)`           |
| s3x2   | 6     | `(0,0) (1,0) (2,0) (0,1) (1,1) (2,1)`           |
| s3x3   | 9     | `(0,0) (1,0) (2,0) (0,1) (1,1) (2,1) (0,2) (1,2) (2,2)` |

Exposed via `StructureLayout.footprintOffsets: [(x: Int, y: Int)]`.

## 3. `Structures.footprintTiles(type:anchorX:anchorY:) -> [(Int, Int)]`

Helper that returns the absolute tile coordinates covered by a structure of `type` anchored at `(anchorX, anchorY)`. Just `anchor + offset` for each pair in `layout.footprintOffsets`. Used by validation + (later slices) for map-tile stamping and ghost preview.

## 4. `Structures.isValidBuildLocation(tileX:tileY:type:structures:units:) -> Int16`

Partial port of `Structure_IsValidBuildLocation`. Signature:

```swift
public static func isValidBuildLocation(
    tileX: Int, tileY: Int,
    type: UInt8,
    structures: StructurePool,
    units: UnitPool
) -> Int16
```

Behaviour (slice 4a subset):

```
for each (fx, fy) in footprintTiles(type, tileX, tileY):
    if fx < 0 || fx >= 64 || fy < 0 || fy >= 64: return 0
    if any structure's footprint covers (fx, fy): return 0
    if any unit's current tile == (fx, fy): return 0
return 1
```

Return value is `Int16` to leave room for the `-neededSlabs` degraded-valid case (slice 4b). For slice 4a we only ever return `0` (invalid) or `1` (valid).

**Deliberate approximations** (see §5):

- **No landscape check.** Building on sand / spice / wall / bloom currently passes validation. Slice 4b adds the `isValidForStructure` / `isValidForStructure2` gate.
- **No slab-prereq degradation.** Slice 4b returns `-n` when `n` tiles under the footprint lack concrete.
- **No adjacent-to-base check.** OpenDUNE requires non-CY buildings to sit next to an existing player structure, concrete slab, or wall (the `g_table_structure_layoutTilesAround` walk). Slice 4b ports this.
- **`notOnConcrete` flag.** Only CONSTRUCTION_YARD sets this; CY can never be built via the panel (`availableCampaign == 99`) so the branch is unreachable via slice-3 UI. Defer until scenario loader rewrite.

## 5. What slice 4a does NOT cover

- **Landscape validation** — every tile type currently passes. The mission-1 player base sits on rock already, so the first useful placement still lands; but silently allowing wall / sand / spice placements is wrong per OpenDUNE.
- **Slab prereq / degradation** — placing a structure without a slab underneath currently doesn't degrade its HP.
- **"Adjacent to player base"** — the mission-1 player can currently build a windtrap in the corner of the map far from their base.
- **`g_debugScenario` branch** — OpenDUNE's scenario loader uses a looser validation path. We don't run through `Structure_IsValidBuildLocation` during scenario init; slice 4a leaves that path untouched.
- **Unit footprint size** — OpenDUNE checks tiles via `Object_GetByPackedTile` which resolves a single-tile unit. We ignore multi-tile-effect units (there aren't any in vanilla, so this is a no-op limitation).

## 6. Scene wiring (`ScenarioScene`)

Two changes:

1. `refreshBuildSidebar()` reads via `StructureInfo.buildableTypesByPriority(from:)` instead of `buildableTypes(from:)`.
2. `commitPlacement(type:tileX:tileY:)` now runs `Structures.isValidBuildLocation(...)` first; invalid → log + reset placement state + refresh sidebar (keeps the sidebar consistent, player sees nothing happen). Valid → existing `Structures.create` path.

When the commit is rejected, we emit a `Log.info` under `build-panel` tracer so the user can see *why* nothing happened. Slice 4b / 5 will turn this into a visible red cursor.

## 7. Testing

### `buildableTypesByPriority`

- Empty bitmask → `[]`.
- `(1 << SLAB_1x1) | (1 << WINDTRAP)` — both types, priorities 2 and 6 → `[0, 9]` (already ascending).
- `(1 << LIGHT_VEHICLE) | (1 << SILO)` — priorities 14 and 12 → `[17, 3]` (SILO first, LIGHT second) — *differs from type-ID order*.
- Full bitmask — matches the §1 table sorted by priority.

### `Structures.footprintTiles`

- `s1x1` at `(5, 5)` → `[(5, 5)]`.
- `s3x3` at `(10, 10)` → 9 tiles from `(10, 10)` to `(12, 12)`.
- Negative or >=64 tile indices pass through (bounds-checking is validation's job, not the helper's).

### `Structures.isValidBuildLocation`

- Empty pools + anchor `(5, 5)`, type WINDTRAP (2×2) → `1`.
- Anchor `(63, 63)` for a 2×2 type → `0` (footprint goes out of bounds at `(64, 63)` / `(63, 64)`).
- Anchor `(-1, 0)` for any type → `0`.
- Existing WINDTRAP at `(5, 5)`, try to build REFINERY at `(4, 4)` (3×2) → `0` (overlap at `(5, 5)`).
- Existing WINDTRAP at `(5, 5)`, try REFINERY at `(10, 10)` → `1`.
- Unit at tile `(5, 5)` (positionX=1280, positionY=1280), build any footprint including that tile → `0`.
- SLAB_1x1 (1×1) at occupied tile → `0`; at empty tile → `1`.

## 8. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/StructureInfo.swift` — `sortPriority` field + `buildableTypesByPriority` + `StructureLayout.footprintOffsets`.
- `Code/Core/Sources/DuneIICore/Simulation/Structures.swift` — `footprintTiles` + `isValidBuildLocation`.
- `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — swap sort helper + gate `commitPlacement`.
- `Code/Core/Tests/DuneIICoreTests/BuildValidationTests.swift` — new suite.
