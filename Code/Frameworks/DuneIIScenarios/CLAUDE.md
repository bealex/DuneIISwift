# DuneIIScenarios

The shared headless model for the behavioural scenario harness (see `Documentation/Architecture/ScenarioHarness.md`). Depends on `DuneIISimulation` + `DuneIIWorld` + `DuneIIFormats` + `DuneIIContracts`; no rendering, no app, no oracle.

Provides: a deterministic 8×8 sand/rock terrain generator, the predefined scenario definitions (moving / close- & far-attack / guarding / move-around-building), a builder that lays out a `GameState` (terrain + two units + optional building + initial actions), and a runner that ticks the scenario while capturing per-tick unit snapshots.

The runner ticks via the real `Simulation.tick()` (the full four-phase loop + `GameLoop_Unit` cadence). With the movement cluster ported, a `moving` unit now **actually crosses the terrain** here and in `scenariolab`; attack/guard units run their scripts until they hit an unported combat native (`Script_Unit_Fire`'s projectile path, `FindBestTarget`, …) and then halt cleanly (they aim/rotate but don't yet fire). The `scenariolab` macOS app renders these for visual assessment; `ScenariosTests` verify layout + that `moving` advances, and `ScenarioGoldenTests` asserts the full `moving` trajectory bit-for-bit vs the OpenDUNE scenario dump.
