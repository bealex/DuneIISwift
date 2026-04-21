# FNT — Bitmap font

Status: Documented 2026-04-19

FNT holds a 256-glyph bitmap font at 4 bits per pixel, indexed directly by ASCII/codepage character code. Dune II ships three fonts in the PAKs — `INTRO.FNT`, `NEW6P.FNT`, `NEW8P.FNT` (and `new6pg.fnt` for German).

References:

- OpenDUNE `src/gui/font.c` · `Font_LoadFile`.
- Our decoder: `Formats.Fnt.Font` in `Code/Core/Sources/DuneIICore/Formats/Fnt/`.

## 1. Layout

```
offset  size  content
0       2     (unused / length field)
2       2     magic: must be 0x0000 0x0500 (i.e. bytes 0x00, 0x05 at [2], [3])
4       2     start          u16 LE — offset of the small info block
6       2     dataStart      u16 LE — offset of per-glyph data-offset table (u16 each)
8       2     widthList      u16 LE — offset of per-glyph width bytes
10      2     widthListEnd   u16 LE — offset one past the width list
12      2     lineList       u16 LE — offset of per-glyph (unusedLines, usedLines) pairs
...
[start + 4]   height        u8
[start + 5]   maxWidth      u8
```

`count = widthListEnd - widthList`. Each of the four per-glyph tables has exactly `count` entries.

Per-glyph storage:

- `widthList[i]` → glyph width in pixels.
- `lineList[i * 2]` → `unusedLines` (blank rows above the glyph).
- `lineList[i * 2 + 1]` → `usedLines` (rows of actual pixel data).
- `dataStart[i * 2 .. +2]` → u16 offset to this glyph's bitmap, or 0 if the glyph is empty (e.g. control codes).

The bitmap is `usedLines` rows of `ceil(width / 2)` bytes. Each byte holds two 4-bit pixels — **low nibble is the left pixel**, high nibble is the right pixel. The pixel values are indices into a 16-color palette the draw routine sets up per call.

## 2. Swift API

```swift
let data = pak.body(named: "NEW8P.FNT")!
let font = try Formats.Fnt.decode(data)
// font.glyphs.count == 256
let a = font[Character("A")]!
// a.pixels is a.width × a.usedLines palette indices (0…15)
```

## 3. Testing

`Core/Tests/DuneIICoreTests/FntTests.swift`:

1. If `DUNE.PAK` is present, decode `NEW8P.FNT` and assert:
   - Magic is accepted.
   - Glyph count ≥ 128 (covers ASCII).
   - The 'A' glyph has non-empty pixel data.
2. A synthetic "wrong magic" buffer is rejected.
