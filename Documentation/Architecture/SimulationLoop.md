# The simulation loop (`DuneIISimulation`)

Design of record for the tick loop, the two-clock model, and the speed/pause behaviour — the foundation the per-type state machines plug into. Ground every decision in OpenDUNE.

## The two clocks

OpenDUNE has two free-running 32-bit tick counters (`src/timer.h`): `g_timerGame` (game time — units, structures, all simulation) and `g_timerGUI` (UI time — animations, status text). `Timer_Tick` (`src/timer.c:361`) bumps each, gated by its own enable bit. **Pause** clears the `TIMER_GAME` bit, so `g_timerGame` freezes while `g_timerGUI` keeps running.

We model this in `GameState` (it owns all mutable state): `timerGame`, `timerGUI`, and `paused`. One `Simulation.tick()` is one loop iteration:

1. `timerGUI &+= 1` (always).
2. if `paused`, return (game clock frozen, no game phases).
3. `timerGame &+= 1`.
4. run the four game-loop phases in order: **Team → Unit → Structure → House**.

This mirrors the headless parity driver (`src/parity.c` `Parity_Run`), which increments both clocks by 1 and runs the four `GameLoop_*` each tick — the deterministic correspondence the parity harness aligns against. Real OpenDUNE drives the same loop from a 60 Hz timer; for headless determinism the tick *is* the unit of simulation, so wall-clock pacing is irrelevant.

## Game speed

`gameSpeed` (0 slowest … 4 fastest; 2 = normal) lives in `GameState`. It does **not** scale the tick counters; instead it scales *durations* via `Tools_AdjustToGameSpeed` (already ported) — at a higher speed an action's "normal" tick-duration maps to fewer ticks, so it completes sooner. `Simulation.adjustToGameSpeed(...)` is the thin wrapper that feeds `state.gameSpeed` in. Per the plan, comparisons against the oracle pin a fixed `gameSpeed`.

## Per-subsystem tick cursors

Each `GameLoop_*` runs every tick, but throttles its sub-activities with "next-due" cursors (`s_tick*` statics in OpenDUNE). These are mutable sim state, so they live in `GameState`. `GameLoop_Unit` (`src/unit.c:123`) gates seven activities; a cursor fires when `cursor <= timerGame`, then advances:

| activity   | interval (ticks) |
|------------|------------------|
| movement   | 3 |
| rotation   | `AdjustToGameSpeed(4, 2, 8, inverse: true)` (4 at normal speed) |
| blinking   | 3 |
| unknown4   | 20 |
| script     | 5 |
| unknown5   | 5 |
| deviation  | 60 |

`Simulation.advanceUnitCadence()` computes which fired this tick (a `UnitTickFlags` set) and advances the cursors, faithfully. The **per-unit work** each flag drives (movement tick, rotation, script step, deviation decay, …) is the per-type state-machine port — landing in the later Phase-3 slices; the cadence is in place and tested now. The Structure/House/Team phases get their own cursors when their logic is ported (they are currently order-preserving stubs).

## Determinism

Same scenario + seed + command stream ⇒ byte-identical run (engine principle 5). `tick()` is pure over `GameState` (a value type), so a run is fully reproducible and a `GameState` copy is a snapshot. The RNG draw *order* deliberately differs from OpenDUNE (Plan §7) — parity is behavioural, not draw-order-identical.

## Testing

The loop foundation is unit-tested directly: clocks advance (pause freezes only the game clock), `adjustToGameSpeed` reflects `state.gameSpeed`, and the unit cadence fires on the right ticks (observed via the cursors / the returned `UnitTickFlags`). Per-slice state-machine parity (Tier-2a decision traces) arrives with each state machine — see `FunctionParityHarness.md`.
