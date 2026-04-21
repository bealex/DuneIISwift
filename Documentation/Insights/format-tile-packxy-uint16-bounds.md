# Tile_PackXY uses uint16 high bits as the out-of-map signal

- **Discovered**: 2026-04-20 · `Code/Core/Sources/DuneIICore/Map/Generator.swift`
- **Category**: format
- **Applies to**: any port of OpenDUNE code that adds offsets to packed tile coordinates (terrain generator, spice spread, AI path queries, projectiles).

## The fact

OpenDUNE's `Tile_PackXY(x, y)` is the C macro `((y) << 6) | (x)` with the result stored in a `uint16`. There are no explicit bounds checks. Out-of-bounds inputs are caught downstream by `Tile_IsOutOfMap(packed) == ((packed) & 0xF000) != 0`, which only catches values whose **high nibble** got set.

This works because two of the three failure modes happen to set those bits when truncated to 16 bits:

- `x = -1` (e.g. neighbour to the west of column 0): `((y) << 6) | (-1)` is `-1` after the OR; the uint16 cast yields `0xFFFF`. `0xF000` bit set ⇒ caught.
- `y = 64` (one past the last row): `(64 << 6)` is `0x1000`. `0xF000` bit set ⇒ caught.
- `y = -1` (neighbour to the north of row 0): `(-1 << 6)` is `-64`; uint16 cast yields `0xFFC0`. `0xF000` bit set ⇒ caught.

But there's a **silent wrap** for `x = 64` (one past the last column): `((y) << 6) | 64` keeps the value below `0x1000`. The result lands on `(y, x=0)` of the next row instead of being rejected. This is intentional in the engine — neighbour walks like the spice-spread 3×3 simply read a different cell when they spill east, and the visual effect is invisible because that "wrong" cell is genuinely adjacent in memory layout.

## Why it matters

A naive Swift port that adds explicit `if x < 0 || x > 63` guards diverges from OpenDUNE on map edges. For purely geometric APIs the divergence is harmless; for anything that consumes RNG (the spice-spread inner loop) any divergence cascades through the rest of the generator and produces a different map. Mirror the `& 0xF000` bit test exactly — including the silent-wrap-east case — when porting tile-walking code.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Map/Generator.swift::addSpiceOnTile` — performs the packed neighbour walk with `((ny << 6) | nx) & 0xFFFF` to get the same uint16 truncation, then tests the `0xF000` mask.
- The same `0xF000` check is used in the bilinear-interpolation pass (`Map.Generator.generate` step 5) and in the `Tile_MoveByRandom` rejection loop (step 8).

## Where it lives in the reference

OpenDUNE `src/tile.h`:

```c
#define Tile_PackXY(x, y)     (((y) << 6) | (x))
#define Tile_IsOutOfMap(p)    (((p) & 0xF000) != 0)
```

Used at the corners of `src/map.c::Map_AddSpiceOnTile` and inside `Map_CreateLandscape`.
