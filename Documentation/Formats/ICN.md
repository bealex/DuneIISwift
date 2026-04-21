# ICN — Terrain tile set

Status: Documented 2026-04-19

ICN is the terrain tile container. The only ICN file in shipped data is `ICON.ICN`, paired with `ICON.MAP`. Tiles are 16×16 pixels at 4 bits per pixel, each tile using a 16-color sub-palette chosen from a per-file palette table. This keeps the tile data small while allowing fog-of-war / shadow / player-color remaps.

References:

- OpenDUNE `src/sprites.c` · `Tiles_LoadICNFile`.
- OpenDUNE `src/file.c` · `ChunkFile_Seek` / `ChunkFile_Read` — the IFF chunk walker.
- Our decoder: `Formats.Icn.TileSet` in `Code/Core/Sources/DuneIICore/Formats/Icn/`.

## 1. Layout

ICN is a standard IFF `FORM`:

```
"FORM" (ASCII, big-endian)
<u32 BE>         outer form size
<4-byte tag>     outer form tag (e.g. "ICON")
[ chunk: <4 tag> <u32 BE size> <data> (padded to even) ]
[ chunk: ... ]
```

### Chunks

| Tag    | Content                                                          |
|--------|------------------------------------------------------------------|
| `SINF` | 4 bytes: widthSize, heightSize, tileCountLo, tileCountHi. Tile width in pixels = `widthSize << 3`; tile height = `heightSize << 3`. For standard 16×16 tiles, both are 2. |
| `SSET` | Tile pixel data. Begins with a 1-byte compression tag (0x00 raw, 0x04 Format80), then 7 bytes of CPS-style header, then the payload. Decoded output: each tile is `(width/2) * height` bytes of 4-bit-packed pixels. |
| `RTBL` | `N` bytes — one per tile — each is an index into `RPAL`.         |
| `RPAL` | `K × 16` bytes — a table of 16-entry sub-palettes. Each entry maps 4-bit pixel values to 256-color PAL indices. |

## 2. Tile expansion

For tile `i`:

1. `paletteIndex = rtbl[i]`
2. `palette = rpal[paletteIndex * 16 ..< (paletteIndex + 1) * 16]`
3. Each packed byte holds two pixels. Upper nibble is the left pixel, lower nibble is the right.
4. Expanded pixel = `palette[nibble]`.

The resulting 256-color index is then resolved through the global PAL (usually `IBM.PAL`) to get the final RGB.

## 3. Swift API

```swift
let data = pak.body(named: "ICON.ICN")!
let tiles = try Formats.Icn.decode(data)
// tiles.tileWidth == 16, tiles.tileHeight == 16
// tiles.pixels(forTile: 12) returns 256 palette indices
```

## 4. Testing

`Core/Tests/DuneIICoreTests/IcnTests.swift`:

1. A synthetic one-tile FORM with a flat sub-palette that maps nibble 1 → 10 and nibble 2 → 20: every expanded pixel is 10 or 20.
2. A non-FORM input raises `notFormForm`.
3. If real `ICON.ICN` is present in `DUNE.PAK`, decode it and assert:
   - `tileWidth == 16`, `tileHeight == 16`.
   - `tileCount` matches `rtbl.count`.
   - `rpal.count` is a multiple of 16.
   - A spot-check on tile 0's pixel expansion has exactly 256 pixels.

## 5. Related insights

- [format-icn-subpalette-indirection](../Insights/format-icn-subpalette-indirection.md) — the RTBL → RPAL → PAL double indirection, and the upper-nibble-is- left-pixel packing.
