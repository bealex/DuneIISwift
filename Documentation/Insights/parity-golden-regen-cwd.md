# Regenerate the function-golden fixtures from the repo root

**Finding:** `opendune --parity-golden=<dir>` must run with the working directory at the **repo root**, because some `Golden_*` dumpers load `Resources/Tiles/Maps/ICON.MAP` (createlandscape, spice, searchspice, tileenterscore, pathfinder). Run from elsewhere (e.g. `cd Repositories/OpenDUNE && ./bin/opendune --parity-golden=…`) and those categories print `ICON.MAP not found — skipped` and their fixtures are **truncated/emptied** — silently clobbering committed goldens.

**Why it matters:** A regen meant to add one category quietly rewrites five unrelated fixtures with fewer/zero records; if committed, those goldens no longer assert anything. Easy to miss because the run reports success.

**Evidence:** `Repositories/OpenDUNE/src/parity.c` `Parity_DumpGolden` (the `Golden_Open` writes one file per category, ICON.MAP-dependent ones first emit the warning). Fixtures under `Code/Tests/WorldTests/Fixtures/`.

**How to apply:** Regenerate from the repo root: `cd <repo> && Repositories/OpenDUNE/bin/opendune --parity-golden=Code/Tests/WorldTests/Fixtures`. **Always `git diff --stat` the Fixtures dir afterward** and `git checkout --` any file you didn't intend to change — a pure-data golden (e.g. `choamprice`, RNG, tile) is CWD-independent, but the ICON.MAP-backed ones are not.
