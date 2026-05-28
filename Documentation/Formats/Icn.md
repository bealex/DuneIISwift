# ICN (tile set)

The terrain/structure map tiles (`ICON.ICN`). Reference: OpenDUNE `Tiles_LoadICNFile` (`src/sprites.c:220`) + `GFX_DrawTile` (`src/gfx.c:210`). Port: `Code/Frameworks/DuneIIFormats/Formats/Icn/Icn.swift`. Tests: `Code/Tests/FormatsTests/IcnTests.swift`.

## Layout

An IFF/FORM container (see `Iff.md`) with chunks:
- `SINF` — geometry codes. `bytesPerRow = info[0] << 2`, `tileHeight = info[1] << 3`, `bytesPerTile = bytesPerRow * tileHeight`. For Dune II (`2,2`) tiles are 16×16, 4-bit, 128 bytes.
- `SSET` — the tile pixels, an `ImageBlock` (raw or Format80). 4 bits per pixel, two pixels per byte: **high nibble = left pixel, low nibble = right**.
- `RTBL` — one byte per tile: the index of the tile's 16-entry palette.
- `RPAL` — a flat array of 16-byte palettes. A tile's palette is `RPAL[RTBL[tile] * 16 ..< +16]`; each 4-bit pixel indexes it to yield an 8-bit main-palette index.
