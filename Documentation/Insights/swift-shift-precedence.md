# Swift shift binds tighter than multiply (opposite of C)

**Finding:** In Swift, `<<`/`>>` are in a higher-precedence group than `*`/`/`. So `(v & 0x3F) * 0x41 >> 4` parses as `(v & 0x3F) * (0x41 >> 4)` = `v * 4`, **not** `((v & 0x3F) * 0x41) >> 4`. This silently corrupted the palette 6→8-bit expansion (`expand6to8(63)` gave 252 instead of 255) until a test caught it. In C, `*` binds tighter than `>>`, so a verbatim port flips meaning.

**Why it matters:** Porting C bit-twiddling verbatim is a core activity in this project (codecs, tables, palettes). Any unparenthesized C expression mixing `*`/`/` with `<<`/`>>` changes meaning when copied into Swift.

**Evidence:** `Palette.expand6to8` in `Code/Frameworks/DuneIIFormats/Formats/Palette/Palette.swift`; test `expansion` in `Code/Tests/FormatsTests/PaletteTests.swift`; OpenDUNE `src/video/video_sdl.c:722`.

**How to apply:** When porting any C expression that mixes shifts with multiply/divide, add explicit parentheses to preserve C's grouping. Never assume `a * b >> c` means the same in both languages.
