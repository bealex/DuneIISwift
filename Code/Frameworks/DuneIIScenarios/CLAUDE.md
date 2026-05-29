# DuneIIScenarios

The shared headless model for the behavioural scenario harness (see `Documentation/Architecture/ScenarioHarness.md`). Depends on `DuneIISimulation` + `DuneIIWorld` + `DuneIIFormats` + `DuneIIContracts`; no rendering, no app, no oracle.

Provides: a deterministic 8×8 sand/rock terrain generator, the predefined scenario definitions (moving / close- & far-attack / guarding / move-around-building), a builder that lays out a `GameState` (terrain + two units + optional building + initial actions), and a runner that ticks the scenario while capturing per-tick unit snapshots.

The `scenariolab` macOS app renders these for visual assessment; the `ScenariosTests` golden tests reproduce them and verify against the OpenDUNE scenario dump. Until the movement/combat/guard natives are ported the units don't move — the harness still builds + renders the setup, and the golden pins the (currently static) per-tick state.
