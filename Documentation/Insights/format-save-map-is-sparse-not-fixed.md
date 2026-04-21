# `MAP ` is a sparse chunk, not a 4096-tile grid dump

- **Discovered**: 2026-04-20 · `Code/Core/Sources/DuneIICore/Formats/Save/SaveTileMap.swift`
- **Category**: format
- **Applies to**: `Formats.Save.TileMap`, any reconstructor that tries to rebuild a full 64×64 map from `MAP ` alone

## The fact

The `MAP ` chunk is *not* a serialisation of all 4096 tiles. It contains only the tiles that differ from the map-seed-generated baseline, plus tiles carrying dynamic state (units, structures, animations, explosions, or lifted fog-of-war). OpenDUNE's `Map_Save` explicitly filters:

```c
if (!tile->isUnveiled && !tile->hasStructure && !tile->hasUnit
    && !tile->hasAnimation && !tile->hasExplosion
    && (g_mapTileID[i] & 0x8000) == 0
    && g_mapTileID[i] == tile->groundTileID) continue;
```

Each record is a `u16 LE cellIndex` (0…4095) followed by 4 packed bytes. Expected body size is `N × 6` where `N` is the *sparse* count, not 4096. Real saves range from a few hundred records (start of a mission with a small scouted region) up toward 4096 as the map is uncovered.

A tile absent from the chunk implies: keep the `Core.Map.Generator` baseline for this seed, leave `overlayTileID = veiledTileID`, `isUnveiled = false`, no owners, no dynamic state.

Related off-by-one: the packed `Tile.index` field (byte 3 of each record) is a pool-reference-plus-one: `0` means "no unit / structure on this tile", `n` means "`UNIT` / `BLDG` pool index `n - 1`". Cross-referencing without subtracting `1` yields wrong pool lookups.

## Why it matters

Anyone reconstructing a loaded save's map state from `MAP ` alone will produce a garbage map — they'd get only the "interesting" tiles and a void for the remaining ~75% of the grid. The baseline has to come from elsewhere: regenerating with `Core.Map.Generator` using `Info.scenario.mapSeed`, then applying the sparse overrides in `TileMap.entries`.

Secondary consequence: naïve size expectations break the decoder. A "tile chunk must be 4096 × tileSize" assertion would reject every real save.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Formats/Save/SaveTileMap.swift` — `TileMap` surfaces `entries: [Entry]` (sparse list), not a 4096-array. `Tile.tileIndex` carries the plus-one semantics verbatim and is documented as such at the declaration.
- `Code/Core/Tests/DuneIICoreTests/SaveTileMapTests.swift:realSave001Map` — pins the sparse invariant: asserts `1 ≤ entries.count ≤ 4096` and ascending `cellIndex` ordering.

## Where it lives in the reference

- OpenDUNE `src/saveload/map.c:93–109` — `Map_Save` skip condition and the `u16 index + 4-byte tile` record emission.
- OpenDUNE `src/saveload/map.c:57–86` — `Map_Load` zeroes all tiles first, then applies sparse records in file order.
- OpenDUNE `src/map.h:40` — `Tile.index` field documented as "index 1 is Structure/Unit 0, etc".
