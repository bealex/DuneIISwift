# Tile geometry & orientation

The map's position math. All pure functions, ported bit-exactly from OpenDUNE `src/tile.c` / `src/tile.h` and golden-verified against the oracle — see `../Architecture/FunctionParityHarness.md`. Swift: `DuneIIWorld/Tile/`.

## `tile32` and packed tiles

`tile32` (`include/types.h:102`) is `{ uint16 x; uint16 y }`. Each coordinate is 16-bit fixed-point: the **high byte** is the tile coordinate (0...63), the **low byte** the sub-tile offset (tile centre is `0x80`, i.e. 128/256). So a unit standing at the centre of tile (3,5) has `x = 0x0380`, `y = 0x0580`.

A **packed** tile is the 12-bit map index `(y << 6) | x` over 0...63 coordinates (the map is 64×64). Conversions (`tile.h` macros, ported as `Tile32`):

- `posX = (x >> 8) & 0x3F`, `posY = (y >> 8) & 0x3F`; `packed = (posY << 6) | posX` (`Tile_PackTile`).
- `Tile_UnpackTile(p)`: `x = ((p & 0x3F) << 8) | 0x80`, `y = (((p >> 6) & 0x3F) << 8) | 0x80` — i.e. the **centre** of the tile.
- `isValid = ((x | y) & 0xC000) == 0` (bits 14-15 clear).

## Distance

`Tile_GetDistance(from, to)` (`tile.c:39`) is "longest axis + half the shortest" on the raw 16-bit coordinates: `dx = |from.x - to.x|`, `dy = |from.y - to.y|`; `max(dx,dy) + min(dx,dy)/2`. (Octagonal approximation of Euclidean distance.) `uint16` wrapping — the Swift port uses `&+`.

- `Tile_GetDistancePacked(a, b)`: unpack both (to centres), `Tile_GetDistance >> 8` → whole tiles.
- `Tile_GetDistanceRoundedUp(from, to)`: `(Tile_GetDistance + 0x80) >> 8`.

## Direction

Two precisions, both "from → to":

- `Tile_GetDirectionPacked` (`tile.c:193`) → coarse 8-step facing as a byte (`0x00, 0x20, …, 0xE0`): build a 4-bit `index` from the signs of `dy`/`dx` plus a "which is bigger, by more than half" test, look up a 16-entry table.
- `Tile_GetDirection` (`tile.c:342`) → precise **signed** 0...255 orientation: halve large deltas (`|dx|+|dy| > 8000`), pick a quadrant from the signs, compute `gradient = (max << 8) / min`, find the first entry of a 32-entry gradient table `≤ gradient`, then fold by quadrant/invert into the 256-step circle. The Swift port keeps everything in `Int` and returns `Int8(truncatingIfNeeded:)`.

## Orientation conversion

`Orientation_Orientation256ToOrientation8(o) = ((o + 16) / 32) & 0x7` and `...16(o) = ((o + 8) / 16) & 0xF` (`tile.c:433`/`:443`) — round the fine orientation to the nearest of 8 / 16 facings (the `+16`/`+8` is the rounding bias).

## Golden fixture

Records in `Code/Tests/WorldTests/Fixtures/primitives-golden.jsonl` (from `opendune --parity-golden`): `Tile_UnpackTile` (9 packed values), `Tile_GetDistancePacked` / `Tile_GetDirectionPacked` (9×9 packed grid), `Tile_GetDistance` / `Tile_GetDistanceRoundedUp` / `Tile_GetDirection` (8×8 `tile32` point grid incl. sub-tile offsets), and both orientation conversions over all 256 inputs. Asserted by `WorldTests/TileGoldenTests`.
