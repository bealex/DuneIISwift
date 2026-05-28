# WSA (animation)

Frame animations. Reference: OpenDUNE `WSA_LoadFile` (`src/wsa.c:194`) + `WSA_GotoNextFrame` (`src/wsa.c:124`). Port: `Code/Frameworks/DuneIIFormats/Formats/Wsa/Wsa.swift`. Tests: `Code/Tests/FormatsTests/WsaTests.swift`.

## Layout

Header (10 bytes): `[frames u16][width u16][height u16][required-buffer u16][has-palette u16]`. Then a frame offset table of `frames + 2` little-endian uint32 entries (the version check: standard if `firstFrameOffset` or `secondFrameOffset` equals `10 + 8 + 4*frames`; else the 8-byte-header old format). An optional 0x300 embedded palette follows the table.

**The table offsets exclude the palette** — actual frame data is at `offset[i] + paletteLength`. Each frame chunk is Format80-compressed; decoding it yields a Format40 XOR delta applied onto the running frame buffer. Frame 0 XORs onto a zero buffer (building the first image); each later frame XORs its delta onto the previous frame. Output: per-frame `width*height` 8-bit indices. The high bit of the frame count (`0x8000`) is a flag and is masked off.
