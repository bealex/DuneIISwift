# Map generator — deterministic landscape from a 32-bit seed

Status: Drafted 2026-04-20 (P2 slice 1 — closes the §3 risk in the Initial plan).

Every Dune II scenario specifies a single 32-bit `Seed` in its `[MAP]` section. From that seed alone the engine reconstructs the full 64×64 landscape (sand / dune / rock / mountain / spice patches) bit-for-bit identically across runs. This document describes the algorithm in our own words, with byte-level invariants.

References:

- OpenDUNE `src/map.c` · `Map_CreateLandscape` and the `_offsetTable[2][21][4]` lookup table.
- OpenDUNE `src/tile.c` · `Tile_MoveByRandom`, `_stepX`/`_stepY` 256-entry tables, `Tile_UnpackTile`, `Tile_Center`.
- OpenDUNE `src/map.c::Map_AddSpiceOnTile` for spice spreading.
- OpenDUNE `src/table/landscapeinfo.c` · `canBecomeSpice` flags per `LandscapeType`.
- Our types: `Core.Map.Generator` in `Code/Core/Sources/DuneIICore/Map/Generator.swift`.

## 1. Overall shape

The generator is a fixed sequence of seven passes, each consuming bytes from a single shared `RNG.ToolsRandom256` instance seeded with the scenario's 32-bit `Seed`. Because every pass advances the same RNG, **every pass that draws bytes must execute in OpenDUNE's exact order, even when its outputs would be identical otherwise**. Skipping or reordering a single `Tools_Random_256()` call permanently desyncs the rest of the map.

```
1.  Fill memory[273] with random nibbles (0..0x0A).
2.  Spread random "blobs" via the 21-entry around[] offset table.
3.  Spread small (0..3) "anti-blobs" via the same table.
4.  Stamp memory[0..255] onto every fourth tile of the 64×64 grid (16×16 anchors).
5.  Bilinearly fill the 4-pixel gaps via the 21-entry _offsetTable.
6.  Average each tile with its 9-neighbour neighbourhood (inclusive).
7.  Threshold the smoothed values into LST_NORMAL_SAND / DUNE / ROCK / MOUNTAIN.
8.  Sprinkle spice "fields" by repeated Tile_MoveByRandom + Map_AddSpiceOnTile.
9.  Map each LST_* into a transition sprite (0..80) using a 4-bit neighbour mask.
10. Resolve each sprite index through the LANDSCAPE icon group to a final tile ID.
```

Steps 1–3 produce a coarse 16×16 noise field. Steps 4–6 upsample and smooth it into a continuous 64×64 height-like field. Step 7 quantises into terrain types. Step 8 lays spice on top. Step 9 chooses transition tiles so neighbouring sprites match (e.g. a rock tile bordered by sand on the north uses a different sprite from one bordered by rock everywhere).

## 2. The `around[]` blob-stamp table (steps 2–3)

```
around = [0, -1, 1, -16, 16, -17, 17, -15, 15, -2, 2, -32, 32, -4, 4, -64, 64, -30, 30, -34, 34]
```

These are 1-D offsets into `memory[273]`. Read on the implicit 16-wide grid, the 21 offsets cluster around the centre cell with a star-burst pattern (centre, plus rings at distance 1, 2, 4 horizontally and 16, 32, 64 vertically). Each blob iteration picks a `base = Tools_Random_256()` (so 0..255) and stamps every offset, clamping the resulting index to `[0, 272]` with `min(max(0, base + off), 272)`.

The clamp means base values near the array edges produce piles of identical writes at index 0 or 272. This is intentional; the resulting bias is part of the canonical map look.

## 3. The 4×4 interpolation lookup `_offsetTable[2][21][4]` (step 5)

The 16 anchors leave a 4×4 hole between each pair. Step 5 fills those holes by averaging two anchor cells. `_offsetTable[parity][k]` is a list of 21 quadruples `(ax, ay, bx, by)` describing two source positions relative to an anchor at `(i*4, j*4)`. The 21 entries cover every interior position of the 5×5 block. Two parity tables exist — `(i+1) % 2` selects between them — to break ties differently on alternating columns and avoid systematic axis-aligned artefacts.

Per quadruple:

```
packed1 = pack(i*4 + ax, j*4 + ay)
packed2 = pack(i*4 + bx, j*4 + by)
packed  = (packed1 + packed2) / 2
if packed is out-of-map, skip.
ground[packed] = (ground[packed1 & 0x3F-x] + ground[packed2 & 0x3F-x or 0] + 1) / 2
```

The `& 0x3F` on the x coordinate of the source positions wraps reads horizontally; the y-axis read can fall off the end (`packed2 >= 64*64`), in which case OpenDUNE substitutes 0 — an enhancement comment in the C source notes this is required to reproduce the original maps. We mirror this byte-for-byte.

## 4. The 9-neighbour averaging pass (step 6)

For each row j, we keep a `previousRow[64]` snapshot (taken before mutating the current row) and a `currentRow[64]` snapshot of the row's pre-mutation values. The neighbour at the current cell uses the cell's own pre-mutation value when off-grid (`i==0 || i==63 || j==0 || j==63`). The sum of nine neighbours is divided by 9 with integer division. A single pass smooths the sharp interpolation edges from step 5.

## 5. Thresholding into landscape types (step 7)

```
spriteID1 = Tools_Random_256() & 0xF
spriteID1 = clamp(spriteID1, 8, 12)
spriteID2 = (Tools_Random_256() & 3) - 1     // signed: -1, 0, 1, or 2
if spriteID2 > spriteID1 - 3 { spriteID2 = spriteID1 - 3 }

for each of the 4096 cells with smoothed value v:
    if v >  spriteID1 + 4 → LST_ENTIRELY_MOUNTAIN
    if v >= spriteID1     → LST_ENTIRELY_ROCK
    if v <= spriteID2     → LST_ENTIRELY_DUNE
    else                  → LST_NORMAL_SAND
```

Two RNG calls; both happen unconditionally even though some seeds will produce a `spriteID2` that's immediately replaced by `spriteID1 - 3`. The second call still advances the RNG — do not short-circuit.

## 6. Spice sprinkling (step 8)

```
i = Tools_Random_256() & 0x2F                  // 0..47 outer iterations
while i-- != 0 {
    repeat {
        packed = pack(rand & 0x3F, rand & 0x3F)  // two RNG draws per attempt
    } until landscape_at(packed) canBecomeSpice
    tile = unpack(packed) (centre = (x*256+128, y*256+128))
    j = Tools_Random_256() & 0x1F              // 0..31 inner iterations
    while j-- != 0 {
        repeat {
            tile' = Tile_MoveByRandom(tile, rand & 0x3F, center: true)
            packed' = pack(tile')
        } until packed' is in-map
        Map_AddSpiceOnTile(packed')
    }
}
```

`Tile_MoveByRandom` (see `tile.c`) draws **two** RNG bytes per call: one for the actual distance (halved until it fits the cap) and one for the orientation. The resulting `(x, y)` lookup uses the 256-entry `_stepX` / `_stepY` tables; we copy them verbatim into Swift.

`Map_AddSpiceOnTile`:

- If the tile is `LST_NORMAL_SAND` or `LST_ENTIRELY_DUNE` (canBecomeSpice == true) → becomes `LST_SPICE`.
- If `LST_SPICE` → becomes `LST_THICK_SPICE`, then recurses (which immediately enters the `LST_THICK_SPICE` branch).
- If `LST_THICK_SPICE` → walk the 3×3 neighbourhood: if every cell's landscape `canBecomeSpice`, leave centre as thick and promote each non-thick neighbour to `LST_SPICE`; otherwise demote centre back to `LST_SPICE`.

Note the recursive call from the `LST_SPICE` branch is bounded — at most one re-entry per call site.

## 7. Sprite-index assignment (step 9)

Each cell now holds an `LST_*` value. Step 9 walks the grid once more and emits a 0..80 sprite index based on a 4-bit neighbour-equality mask:

```
mask = (up == self) * 1 + (right == self) * 2 + (down == self) * 4 + (left == self) * 8

LST_NORMAL_SAND       → 0
LST_ENTIRELY_ROCK     → mask + (mask of LST_ENTIRELY_MOUNTAIN neighbours) + 1   (range 1..16)
LST_ENTIRELY_DUNE     → mask + 17                                               (range 17..32)
LST_ENTIRELY_MOUNTAIN → mask + 33                                               (range 33..48)
LST_SPICE             → mask + (mask of LST_THICK_SPICE neighbours) + 49        (range 49..64)
LST_THICK_SPICE       → mask + 65                                               (range 65..80)
```

Edge cells use their own value as the off-grid neighbour (so the mask bit for that edge is set: matches itself).

The two `mostlyRock`/`partialMountain` mixings on the LST_ENTIRELY_ROCK and LST_SPICE rows make those types blend visually with their thicker variants.

## 8. Final tile IDs (step 10)

`finalTileID = iconMap[iconMap[ICM_ICONGROUP_LANDSCAPE] + spriteIndex]`

In our types: `tileResolver.iconMap.tileId(in: .landscape, offset: spriteIndex)`. After this pass, every cell's `groundTileID` is a real ICN tile ID ready for rendering.

## 9. Worked example — one RNG byte

For the Atreides mission 1 seed `0x16BD` (4-byte seed in `SCEN001.INI`), `RNG.ToolsRandom256` initialises to `(a, b, c, d) = (0xBD, 0x16, 0x00, 0x00)`. The first `next()` call returns `0x9C` (verified against the pinned baseline in `Documentation/Algorithms/RNG.md`). The first `memory[0]` therefore becomes `0x9C & 0x0F = 0x0C`, then capped to `0x0A`. This single trace is enough to confirm the RNG / nibble-mask path is wired up correctly before the larger pass-1 baseline takes over.

## 10. Public API

```swift
public extension Map {
    enum Generator {
        /// Builds a fresh 64×64 Map from a scenario seed. Pure function;
        /// safe to call concurrently with different seeds.
        public static func generate(seed: UInt32, resolver: TileResolver) -> Map
    }
}
```

The output `Map` has every cell's `groundTileID` populated and every other field at its zero default. Callers are expected to follow up with `Map.applyMapField(...)` to overlay the scenario's explicit spice fields, blooms, and structure spawns.

## 11. Testing

`Core/Tests/DuneIICoreTests/MapGeneratorTests.swift`:

1. **Determinism.** Two `generate(seed:resolver:)` calls with the same seed produce identical `Map.cells`.
2. **Range invariant.** Every output `groundTileID` lies in `[landscapeTileID, landscapeTileID + 80]` — i.e. resolves to a valid sprite from the LANDSCAPE icon group.
3. **Distinct seeds differ.** `generate(seed: A)` ≠ `generate(seed: B)` for two distinct seeds.
4. **Pinned baseline.** For seed `0x16BD` (Atreides M1) and a synthetic IconMap with `landscapeTileID = 1000`, specific cells `(0,0)`, `(32,32)`, `(63,63)` produce specific tile IDs (regression pin).
5. **Histogram sanity.** The four major landscape types are each represented in a typical seed's output (no all-rock or all-sand maps for normal seeds).
6. **Real install (short-circuits when absent).** With the real `ICON.MAP` and seed `0x16BD`, the first cell's tile ID falls inside the LANDSCAPE group's actual range.

## 12. Related insights

- See `Documentation/Algorithms/RNG.md` for the `Tools_Random_256` PRNG that drives every step.
- A future insight (`map-generator-rng-ordering.md`) will capture the "every pass advances the same RNG, do not skip or reorder draws" rule once we have a regression to point at.
