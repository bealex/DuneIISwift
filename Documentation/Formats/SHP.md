# SHP — Sprite frames

Status: Documented 2026-04-19

SHP is Dune II's sprite container. Each file holds one or more 8-bit paletted frames; game code indexes into the frame array (e.g. sprite 47 is a specific unit facing). Used for `UNITS.SHP`, `SHAPES.SHP`, `MOUSE.SHP`, `ARROWS.SHP`, etc.

References:

- OpenDUNE `src/sprites.c` · `Sprites_Load` (file header walker).
- OpenDUNE `src/gui/gui.c` · `GUI_DrawSprite` header at lines 920-930 (our primary reference for the per-frame header layout).
- Our decoder: `Formats.Shp.FrameSet` in `Code/Core/Sources/DuneIICore/Formats/Shp/`.

## 1. File-level header

```
offset  size  content
0       2     frame count (u16 LE)
2       ???   frame offset table (variable width — see below)
```

**Two format variants** exist in shipped data:

- **Modern** (Dune II v1.07): offsets are **u32 LE**, one per frame. The first offset equals `4 + count * 4`, which is how OpenDUNE detects the format — it reads the u32 at offset 2 and compares it to that expected value.
- **Legacy** (Dune II v1.00): offsets are **u16 LE**.

Every target PAK we ship uses the modern variant; the legacy path is implemented but not exercised by real data.

**Extra 2-byte prefix**: on modern files, each frame's `offset` points 2 bytes *before* the real frame header (those 2 bytes contain an RLE-type/reserved tag that the game ignores). We skip them.

## 2. Per-frame header

From the comment block at `gui.c:920-930` — each frame begins with 10 bytes:

```
0x00  u16 LE  flags       bit0 = has 16-byte house palette
                          bit1 = 1 → raw pixels, 0 → Format80-compressed
0x02  u8      height
0x03  u16 LE  width
0x05  u8      height (duplicated; we ignore it)
0x06  u16 LE  packed size including header (advisory; we ignore it)
0x08  u16 LE  decoded size (always width × height)
0x0A          [16 bytes of house palette — only if flags & 1]
0x0A+...      pixel data — raw or Format80 stream
```

The 16-byte "house palette" is a slice of 16 palette indices the draw routine remaps through when a unit belongs to a specific house. It does not cover the full 256-entry palette.

## 3. Swift API

```swift
let data = pak.body(named: "UNITS.SHP")!
let set = try Formats.Shp.decode(data)
let frame = set.frames[47]
// frame.width × frame.height palette indices in frame.pixels
```

`Frame.pixels.count == width * height` is asserted by the decoder.

## 4. Testing

`Core/Tests/DuneIICoreTests/ShpTests.swift`:

1. Synthetic single-frame raw SHP encodes and decodes exactly.
2. Format80-compressed synthetic frame round-trips.
3. Real input: if `DUNE.PAK` is present, `MOUSE.SHP` parses into ≥ 1 frame and every frame passes the `pixels.count == w * h` invariant.

## 5. Related insights

- [format-shp-offset-table-overlap](../Insights/format-shp-offset-table-overlap.md) — `offset[0] == 4 + count * 4` overlaps with the last offset entry; the frame header starts at `offset[i] + 2`.
- [format-shp-row-rle-transparency](../Insights/format-shp-row-rle-transparency.md) — Format80 decode is not the final pixel buffer; a second row-RLE pass expands `0x00 N` runs into N transparent pixels.
