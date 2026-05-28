# FNT (bitmap font)

Bitmap fonts for text rendering. Reference: OpenDUNE `Font_LoadFile` (`src/gui/font.c:59`) + `GUI_DrawChar` (`src/gui/gui.c:398`). Port: `Code/Frameworks/DuneIIFormats/Formats/Fnt/Fnt.swift`. Tests: `Code/Tests/FormatsTests/FntTests.swift`.

## Layout

Header (little-endian uint16 offsets into the file): magic `00 05` at bytes 2–3; an info-block offset (`@4`), a glyph data-pointer table (`@6`), a per-glyph width table (`@8`), and a line table (`@12`). Glyph count = `u16@10 - widthTable`. From the info block: `height = byte[start+4]`, `maxWidth = byte[start+5]`.

Per glyph: `width` (one byte), `unusedLines`/`usedLines` (line table, two bytes), and a data pointer (0 = no bitmap). The bitmap is 4-bit packed nibbles, `(width+1)/2` bytes per row, `usedLines` rows — **low nibble = left pixel, high nibble = right**. Color index 0 is transparent. Glyphs render into a `width × height` cell offset down by `unusedLines`.
