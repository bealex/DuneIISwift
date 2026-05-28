# Palette (VGA, 6-bit)

256 colors with 6-bit RGB components (0…63), stored as 768 raw bytes in `IBM.PAL` and embedded in CPS/WSA files. Reference: `File_ReadBlockFile("IBM.PAL", …)` (OpenDUNE `src/opendune.c:314`) and the 6→8-bit expansion in the video driver (`src/video/video_sdl.c:722`). Port: `Code/Frameworks/DuneIIFormats/Formats/Palette/Palette.swift`. Tests: `Code/Tests/FormatsTests/PaletteTests.swift`.

The raw 6-bit values are the source of truth. Display expansion to 8 bits is exactly `out8 = (value6 * 0x41) >> 4` (maps 0→0, 63→255) — note `0x41` then `>> 4`; do not simplify to `value << 2`. Expansion is a display concern; `Palette` keeps the 6-bit values and offers `expand6to8` / `rgba8` for renderers.

See insight `swift-shift-precedence` — the `* 0x41 >> 4` expression needs parentheses in Swift, where `>>` binds tighter than `*`.
