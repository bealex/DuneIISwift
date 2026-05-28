# SHP sprites carry no palette — some need a context palette (mentat faces)

**Finding:** SHP frames are 8-bit palette indices with **no embedded palette**; the correct palette is contextual. Most sprites use IBM.PAL, but the **mentat face sprites** (`MENSHP[H/A/O/M].SHP`) are drawn over the `MENTAT<house>.CPS` background and use **its** embedded palette (OpenDUNE `gui/mentat.c:494`: filename built as `MENTAT%c.CPS` from the house initial). Rendering them with IBM.PAL scrambles the colors (the reported MENSHPM bug). `MENTATM.CPS` etc. live in DUNE.PAK.

**Why it matters:** "colorize every SHP with IBM.PAL" is wrong for context-dependent sprites (mentat, and likely some menu/UI sprites). The palette must follow the screen the sprite is drawn over.

**Evidence:** `mentatPalette(for:)` in `Code/Apps/rendertest/ContentView.swift`; `AssetLibrary.cpsPalette`; OpenDUNE `gui/mentat.c:494-495` (note it also overlays `BENE.PAL` in one branch — not yet reproduced).

**How to apply:** When rendering a sprite, use the palette of the screen/CPS it belongs to, not a global default. In the eventual game, mentat/menu screens set the palette from their CPS before drawing sprites.
