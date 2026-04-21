# `ODUN` is an OpenDUNE-only chunk; original 1.07 saves never emit it

- **Discovered**: 2026-04-20 · `Code/Core/Tests/DuneIICoreTests/SaveTests.swift`
- **Category**: format
- **Applies to**: `Formats.Save.Container`, any loader that inspects chunk presence to gate behaviour

## The fact

The `_SAVE00?.DAT` files that ship with Westwood's Dune II 1.07 (`Repositories/patched_107_unofficial/`) contain only six chunks: `NAME`, `INFO`, `PLYR`, `UNIT`, `BLDG`, `MAP ` (note trailing space). `ODUN` is a container extension invented by OpenDUNE's save writer — a "new unit" chunk carrying fields the legacy `UNIT` record didn't hold. It never appears in original-game saves. `TEAM` is conditional on the scenario actually having allocated AI teams and is similarly absent from the supplied saves.

## Why it matters

If a Save reader asserts that all eight chunks documented in OpenDUNE's `load.c` must be present, it will reject every real Dune II save. Real 1.07 saves are a strict subset. Our decoder therefore surfaces the chunk set as-found rather than validating against a fixed expected list, and per-chunk loaders have to reconstitute missing state (e.g. the extended unit fields normally supplied by `ODUN`) from the `UNIT` chunk alone.

The same logic will apply in reverse when we eventually emit saves: writing `ODUN` would make our saves forward-incompatible with an original-game reader in a way the vanilla game never generated.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Formats/Save/SaveContainer.swift` — walker indexes chunks into a `[String: Data]` keyed by 4CC. No fixed chunk-set assertion.
- `Code/Core/Tests/DuneIICoreTests/SaveTests.swift:realSave001` — asserts the six-chunk vanilla set, not the eight-chunk OpenDUNE superset.

## Where it lives in the reference

- OpenDUNE `src/save.c` · `Save_Main` writes `NAME`, `INFO`, `PLYR`, `UNIT`, `BLDG`, `MAP `, `TEAM`, `ODUN` unconditionally — but that writer is OpenDUNE's, not the original.
- OpenDUNE `src/load.c` · `Load_Main` switch falls through for unknown tags with a warning, which is how OpenDUNE itself stays compatible with vanilla saves.
- Raw bytes of `Repositories/patched_107_unofficial/_SAVE001.DAT` — inspecting the file via our container walker yields exactly six chunks.
