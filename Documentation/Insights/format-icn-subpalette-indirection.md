# ICN tiles are 4-bit pixels indirected through a per-tile 16-byte sub-palette

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Formats/Icn/IcnTileSet.swift`
- **Category**: format
- **Applies to**: `Formats.Icn.TileSet`, the future terrain atlas builder.

## The fact

An ICN file is an IFF `FORM` with four chunks: `SINF`, `SSET`, `RTBL`, `RPAL`. A 16×16 tile is stored as 128 bytes of packed 4-bit pixels in `SSET`. To render:

1. `paletteIndex = RTBL[tileIndex]` — one byte per tile.
2. `subPalette = RPAL[paletteIndex * 16 ..< (paletteIndex + 1) * 16]` — 16 palette slots.
3. For each packed byte: **upper nibble is the left pixel, lower is the right**. Each 4-bit value is the sub-palette slot.
4. The slot value is an index into the global 256-color PAL.

Tiles therefore consume only 16 colors each, chosen from the full palette. That's how fog-of-war, shadow, and faction-tint variants share the same tile pixels.

## Why it matters

Rendering a tile without the double-indirection yields noisy garbage — the naked 4-bit values look like indices into IBM.PAL's first 16 slots, which are action colors (white, yellow, etc.), not terrain.

## Where it lives in our code

- `Formats.Icn.TileSet.pixels(forTile:)` — the indirection.
- `Tests/DuneIICoreTests/IcnTests.swift::synthetic` exercises a hand-built one-tile FORM.

## Where it lives in the reference

OpenDUNE `src/sprites.c::Tiles_LoadICNFile` reads all four chunks; `src/gfx.c::GFX_Init_TilesInfo` decodes `SINF[0..1]` as `widthSize/heightSize` where each is multiplied by 8 to get pixel dimensions (`tileByteSize = (width/2) * height`).
