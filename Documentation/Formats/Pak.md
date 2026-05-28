# PAK (archive container)

The container format for the original install's data files. Reference: OpenDUNE `src/file.c` PAK handling and `src/tools/extractpak.c` (the clean standalone reader); cross-check `Repositories/dunepak/`. Port: `Code/Frameworks/DuneIIFormats/Formats/Pak/Pak.swift`. Tests: `Code/Tests/FormatsTests/PakTests.swift`.

## Layout

A table of entries followed by file data:

```
[u32 LE offset0][name0\0][u32 LE offset1][name1\0] … [u32 LE 0]   <- table, terminated by a zero offset
… file data, each entry's bytes at its offset …
```

An entry's size = the next entry's offset minus its own; the last entry runs to end-of-file. Names are NUL-terminated ASCII. Lookup is case-insensitive (matching the original file layer). Many assets (ICON.ICN, SHPs, CPSs, UNIT.EMC, …) live inside `DUNE.PAK`; scenarios in `SCENARIO.PAK`; sounds in `VOC.PAK`.
