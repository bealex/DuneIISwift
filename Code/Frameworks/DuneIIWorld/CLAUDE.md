# DuneIIWorld

The runtime data model and the single owned mutable-state aggregate. Depends on `DuneIIContracts` + `DuneIIFormats`.

Holds the POD model (`Unit`/`Structure`/`House`/`Team`/`Map`/`Scenario`), the object pools (fixed arrays + dense find-index), the static stat tables (a literal port of OpenDUNE `table/*info.c`, as Swift `let`), and `GameState` — which owns ALL mutable simulation state: both RNGs, the two clocks, the per-subsystem tick cursors, and the build-availability flags hoisted out of the "static" tables. Also scenario `.INI` loading, our save/load, and the original-save converter.

No global mutable state — it belongs in `GameState`. Populated in Phase 2. See `Documentation/Plan.v1.md` and `Documentation/Architecture/Overview.md`.
