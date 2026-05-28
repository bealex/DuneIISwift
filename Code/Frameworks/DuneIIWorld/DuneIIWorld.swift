/// The runtime data model and the single owned mutable state aggregate.
///
/// Will define `Unit`/`Structure`/`House`/`Team`/`Map`/`Scenario`, the object pools, the static
/// stat tables (a literal port of OpenDUNE's `table/*info.c`), and `GameState` — which owns all
/// mutable simulation state (both RNGs, the two clocks, the per-subsystem tick cursors, the
/// build-availability flags). Also scenario `.INI` loading, our save/load, and the original-save
/// converter. Populated in Phase 2 — see `Documentation/Plan.v1.md`.
public enum DuneIIWorld {}
