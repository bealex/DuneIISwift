# IFF / FORM (chunk container)

The EA-IFF chunk container used by ICN tilesets, EMC scripts, and savegames. Reference: OpenDUNE `ChunkFile_*` (`src/file.c:1039`) and the savegame reader `Load_FindChunk` (`src/load.c:30`). Port: `Code/Frameworks/DuneIIFormats/Formats/Iff/Iff.swift`. Tests: `Code/Tests/FormatsTests/IffTests.swift`, `SaveContainerTests.swift`.

## Layout

```
"FORM" [u32 BE total length] [4CC form type]   <- header (12 bytes)
  [4CC] [u32 BE length] [payload, padded to even] …   <- chunks
```

All scalars big-endian. Chunks are word-aligned (odd lengths get a pad byte). The form type is `ICON` for tilesets, `SCEN` for savegames, etc. `Iff.Reader` exposes `formType` and `chunk(_ id:)`; 4CCs may contain spaces (e.g. `"MAP "`). The savegame container is exactly this shape (`FORM`/`SCEN` + NAME/INFO/PLYR/UNIT/BLDG/`MAP `/TEAM/ODUN chunks), so the same reader serves it.
