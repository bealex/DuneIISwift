# SHP (sprite set)

Sprite frames for units, structures, and UI. Reference: OpenDUNE `Sprites_Load` (`src/sprites.c:60`) + the frame decode in `GUI_DrawSprite` (`src/gui/gui.c:1015`). Port: `Code/Frameworks/DuneIIFormats/Formats/Shp/Shp.swift`. Tests: `Code/Tests/FormatsTests/ShpTests.swift`.

## Layout

`[u16 LE frame count][offset table]`. The table has 2-byte entries (old Dune v1.0) or 4-byte entries (v1.07), distinguished by whether `4 + count*4` equals the dword at offset 2. **New-format frame pointers are `offset + 2`.**

Per frame: a 10-byte header `[flags u16][height u8][width u16][height-dup u8][packed size u16][decoded size u16]`, an optional 16-byte lookup table (flag bit 0), then the pixel payload. Flag bit 1 means the payload is already a raw zero-run RLE; otherwise it is Format80-compressed (decode to `decoded size` first). The RLE then expands to `width*height` 8-bit indices: a nonzero byte is one literal pixel (mapped through the 16-byte lookup if present); a `0x00` byte is followed by a run length of transparent (index 0) pixels.
