# Unit sprite IDs are global indices into a concatenated array; grouping lives only in the tables

**Finding:** `unitInfo`'s `groundSpriteID`/`turretSpriteID` are **not** local frame indices into one SHP — they index a **global** array of all SHPs concatenated in a fixed load order (`Sprites_Init`, `src/sprites.c:485`): MOUSE 0–6, BTTN 7–11, SHAPES 12–110, **UNITS2 111–150, UNITS1 151–237, UNITS 238–354**, … To map a unit to a frame in a specific SHP file, subtract that file's base offset. Separately: the frame→logical-sprite grouping and the directional-vs-animation distinction are **only** in `g_table_unitInfo` (`displayMode` + the `viewport.c` orientation tables), never in the SHP itself.

**Why it matters:** A tool that opens a single SHP sees 0-indexed local frames; the game's sprite IDs are global. Off-by-base-offset → wrong sprites. And you can't infer "these 5 frames are one tank's 8 facings" from the SHP — it must come from the table.

**Evidence:** `SpriteCatalog` (`Code/Frameworks/DuneIIRenderer/SpriteCatalog.swift`) encodes the per-file local frame ranges + directional/animation labels; OpenDUNE `src/sprites.c:485-514` (load order), `src/table/unitinfo.c` (per-unit sprite IDs + displayMode), `src/gui/viewport.c:334-724` (orientation tables → frame counts).

**How to apply:** When `DuneIIWorld` ports `unitInfo`, keep sprite IDs as global indices plus the load-order base offsets, and reconcile `SpriteCatalog` with that port so the grouping data lives in one place. On-map *structures* use a different grouping (ICN tiles via `ICON.MAP` iconGroups + `structureInfo.iconGroup`), not unit SHPs.
