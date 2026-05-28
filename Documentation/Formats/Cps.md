# CPS (full-screen image)

320×200 8-bit images (menus, screens). Reference: OpenDUNE `Sprites_LoadCPSFile` (`src/sprites.c:299`) + `Sprites_Decode` (`src/sprites.c:186`). Port: `Code/Frameworks/DuneIIFormats/Formats/Cps/Cps.swift`. Tests: `Code/Tests/FormatsTests/CpsTests.swift`.

## Layout

`[u16 LE file size][u16 compression type][u32 uncompressed size][u16 palette size]`, then an optional embedded palette (`palette size` bytes; 768 = a full VGA palette), then the image body. Compression type `0x0` = raw, `0x4` = Format80 (the only two Dune II uses). The body decodes to a 64000-byte (320×200) buffer of 8-bit palette indices. The shared raw/Format80 dispatch is `ImageBlock` (also used by ICN's SSET chunk).
