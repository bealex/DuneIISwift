# Many CPS/WSA/SHP assets carry no palette — the correct one is loaded separately at runtime

**Finding:** Several presentation assets have **no embedded palette**; the engine loads a separate `.PAL` (or relies on the ambient game palette) for them. Confirmed by inspecting the real install:

- **`MENTAT[H/A/O/M].CPS`** — `paletteSize == 0`, no embedded palette. The mentat portrait is drawn under whatever palette is already active. Only the **mercenary** mentat overrides it: `GUI_Mentat_Display` does `File_ReadBlockFile("BENE.PAL", g_palette1, ...)` for `HOUSE_MERCENARY` (`gui/mentat.c:500`). The other three houses use the ambient **IBM.PAL**.
- **`MENSHP[H/A/O/M].SHP`** — SHP frames are bare 8-bit indices (no palette). The mercenary face (`MENSHPM.SHP`) therefore needs **BENE.PAL**; the others use IBM.PAL.
- **Intro / finale WSAs** (`INTRO*`, `AFINAL*`/`EFINAL*`/`HFINAL*`/`OFINAL*`) — all have `hasPalette == 0`. They are played under **INTRO.PAL**, loaded once by `GameLoop_PrepareAnimation` (`cutscene.c:82`) for both the intro and the end-game animation. Continuation WSAs (the `B`/`C` parts) have `firstFrameOffset == 0` and naturally embed nothing.

**Correction:** A previous version of this note claimed the mentat faces used the *embedded* palette of their `MENTAT<house>.CPS`. That is false — those CPS files embed no palette. `Sprites_LoadCPSFile` only copies a palette when `paletteSize != 0` (`sprites.c:323`); for these it leaves the active palette untouched.

**Why it matters:** "colorize with IBM.PAL" and "use the file's embedded palette" are both wrong for context-dependent assets. Rendering them with the wrong palette scrambles the colors (the reported MENTATM.CPS / MENSHPM.SHP / INTRO*/?FINAL* WSA bugs). `BENE.PAL`, `INTRO.PAL`, `IBM.PAL` all live inside the PAKs (DUNE.PAK / INTRO.PAK).

**Evidence:** `contextPalette(for:)` + `AssetLibrary.palette(named:)` in `Code/Apps/rendertest/`; OpenDUNE `gui/mentat.c:488-500`, `cutscene.c:58-82`, `sprites.c:299-331`. See [[render-palette-animation]] (these palettes must NOT be palette-cycled — the cycle is for IBM.PAL gameplay only).

**How to apply:** When rendering an asset that embeds no palette, resolve its context palette by name/role (mercenary mentat → BENE.PAL, cutscene WSA → INTRO.PAL), falling back to IBM.PAL. In the eventual game, the screen/cutscene flow sets `g_palette1` before drawing — replicate that, don't guess from the file alone.
