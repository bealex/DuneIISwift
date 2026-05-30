# Off-viewport units throttle their scripting (3 vs 52 opcodes/tick)

**Finding.** `GameLoop_Unit` runs a unit's EMC script for `SCRIPT_UNIT_OPCODES_PER_TICK + 2` (= 52) opcodes per script-tick **only if the unit is on-screen** (`Map_IsPositionInViewport`); an off-viewport unit (and not flagged `scriptNoSlowdown`) gets **3** opcodes/tick. So a unit's *behaviour timing* depends on the camera position — `g_viewportPosition`.

**Why it matters.** It's a render-ish global that silently feeds the deterministic sim. A unit placed far from the pinned parity viewport reaches `CalculateRoute`/`Fire`/etc. ~17× slower, so a movement/combat trajectory diverges from the oracle by tens of ticks even though every primitive is bit-correct. This caused the `move-trike` golden (a trike at tile 40:40, off the oracle's pinned `(12,12)` viewport) to diverge until the throttle was modelled.

**How to apply.** `GameState.viewportPosition` + `Tile32.isPositionInViewport` are ported; `Simulation.gameLoopUnit` picks the 3-vs-52 budget from them. Parity tests must pin `viewportPosition` to the oracle's value (`Tile32.packXY(x:12,y:12)` for `--parity-scenario`); the lab points it at the active region for full-speed scripting. Code: `DuneIISimulation/Simulation.swift` (tickScript budget), `Tile32.isPositionInViewport`; oracle `parity.c` `g_viewportPosition = Tile_PackXY(12,12)`.
