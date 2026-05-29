# Unit tile-enter scoring (`Unit_GetTileEnterScore`)

The pathfinder's per-tile cost function: given a unit and a destination tile (plus the direction it would arrive from), how desirable / costly is it to step there? This is the leaf the A*-ish pathfinder (`Script_Unit_Pathfinder`, Tier F #21) calls for every candidate neighbour. Reference: OpenDUNE `src/unit.c:2335` (`Unit_GetTileEnterScore`), with two helpers — `src/unit.c:660` (`Unit_IsValidMovementIntoStructure`) and `src/structure.c` (`Structure_Get_ByPackedTile`).

We pin `g_dune2_enhanced = false` (the 1.07 path) per `Plan.v1.md` — so the landscape-speed line is `res = movementSpeed[movementType]` (no `movingSpeedFactor / 256` scaling).

## `Structure_Get_ByPackedTile` (World pool query)

Mirror of the existing `unitGetByPackedTile`. Off-map → none; tile not flagged `hasStructure` → none; otherwise the structure slot is `g_map[packed].index - 1` (the map index is 1-based). Lives on `GameState` (World), alongside `unitGetByPackedTile`.

## `Unit_IsValidMovementIntoStructure` → `UInt16`

Returns `0` (cannot enter), `1` (move onto / close), or `2` (actually enter). Logic:

- **Other owner** (`Unit_GetHouseID(unit) != s.houseID`):
  - A **saboteur** whose `targetMove` is this structure → `2` (saboteurs always enter).
  - A **foot unit** targeting a **conquerable** structure → `2` if it is its `targetMove`, else `1` (move close). Anyone else → `0`.
- **Same owner:**
  - If the structure's `enterFilter` bitmask does not include this unit's type → `0`.
  - If the structure's script variable `[4]` already equals this unit's encoded index → `2` (OpenDUNE's own "TODO -- Not sure"; transcribed verbatim).
  - Otherwise enter only if the structure is not already linked to another unit: `linkedID == 0xFF ? 1 : 0`.

`Unit_GetHouseID` is the existing `GameState.unitHouseID` (a deviated unit is Ordos in 1.07). Encoding uses the existing `GameState.indexEncode`.

## `Unit_GetTileEnterScore(unit, packed, orient8)` → `Int16`

Returns `256` when the tile is not accessible, a negative `-res` (`-1` / `-2`) for an accessible structure, or an inverted-speed score otherwise (lower = faster ⇒ cheaper). Order, exactly:

1. Invalid map position **and** the unit is not a winger → `256`.
2. If another unit (different index) occupies the tile and the mover is **not** a sandworm:
   - mover is a **saboteur** targeting that unit → `0`;
   - the occupant is **allied** → `256`;
   - the occupant is not on **foot**, or the mover is not **tracked**/**harvester** → `256` (i.e. only a tank/harvester may crush an enemy foot soldier).
3. If a structure occupies the tile → `Unit_IsValidMovementIntoStructure`; `0` ⇒ `256`, else `-res`.
4. Otherwise the landscape type's `movementSpeed[movementType]` is the base `res`.
   - Saboteur onto a non-allied **wall** → `res = 255` (max — it will breach it).
   - `res == 0` (impassable terrain) → `256`.
   - **Diagonal** arrival (`orient8 & 1`): `res -= res/4 + res/8` (≈ ×0.625, the longer diagonal step is cheaper per tile).
   - Invert to a rough time estimate: `res ^= 0xFF`; return as `Int16`.

## Placement

`Unit_GetTileEnterScore` + `Unit_IsValidMovementIntoStructure` are added to the replaceable `UnitPrimitives` protocol (`DefaultUnitPrimitives`). They read `GameState` (pools + map + tile-id bases + scenario scale + player house) and compose the sibling `MapPrimitives` (`isValidPosition`/`landscapeType`) and `HousePrimitives` (`areAllied`), which are passed in — keeping the injected-seam discipline (no static free functions).

## Testing

- **Golden (landscape path):** `Golden_TileEnterScore` builds a generated map (`Map_CreateLandscape`) with no units/structures placed and sweeps `Unit_GetTileEnterScore` over every movement type × several packed tiles × both diagonal/orthogonal arrivals, dumping the score. The Swift port reproduces it bit-for-bit (`TileEnterScoreTests`). The oracle dump runs with `g_dune2_enhanced = false` pinned (added to `Parity_DumpGolden`) to match the 1.07 path.
- **Decision-trace (occupied paths):** Swift unit tests construct a `GameState` with a placed enemy/allied unit and a placed conquerable/non-conquerable structure, asserting each branch of steps 2–3 and of `Unit_IsValidMovementIntoStructure` against the transcribed logic.
