# Route-driven orientation must lock to `route[0] * 32`, not recompute from pos32

- **Discovered**: 2026-04-21 · `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift:240..256`
- **Category**: simulation
- **Applies to**: `Scheduler.tickMovement`, any code that wants "continuous-looking" sprite rotation for discretely-routed units

## The fact

Unit sprites pick their 8-way octant via `Orientation.to8(raw256) = ((raw256 + 16) / 32) & 7`. Octants 0..4 render N/NE/E/SE/S with `flipHorizontal = false`; octants 5..7 render SW/W/NW using the E-side sprites **mirrored** (`xScale < 0`). So the sprite-flip bit toggles at orientation byte ≈ 144, 208, 240.

When a unit follows a pathfinder-built route, each step is one of 8 compass directions (`route[0] ∈ 0..7`, with `route[0] * 32` landing square on the octant midpoints: 0, 32, 64, …, 224). If `tickMovement` *recomputes* orientation every tick from the **continuous** pos32 delta `(goal − position)`, tiny cross-axis drift (e.g. the unit being 6 px west of the tile centerline while heading N) tips the byte across an octant boundary — producing a single-tick "NW" sprite, then back to "N", then maybe another flicker. Visibly: the sprite **blinks**.

Fix: while following a route step, set `orientationCurrent = route[0] * 32` every tick. That's the canonical midpoint of the step's octant; it doesn't drift and doesn't flip. Only fall back to the continuous pos32 direction when there's no route — the `SetDestinationDirect` / `targetMove` straight-line fallback path, which is short-lived.

OpenDUNE's `Script_Unit_CalculateRoute` (`src/script/unit.c:1296`) does exactly this alignment when it fills the route — our port mirrors it in `Functions.swift` at `makeCalculateRouteUnit`. The bug was that `tickMovement` then **overrode** the aligned orientation each step with a continuous recompute.

## Why it matters

The sprite atlas is designed around 8 cardinal octants. Route directions are also 8 cardinal octants. Any interpolation between them via continuous math invites off-by-one octant flicker — especially on long north/south runs where the unit is stepping by `max(4, speed/4)` px per tick and cross-axis drift accumulates from integer division rounding.

Test of the same shape would catch it for any future movement refactor: put a unit a few pixels off the tile centerline, give it a route step, tick, assert orientation matches `route[0] * 32` exactly.

## Where it lives in our code

- Orientation pin: `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift:251..255`.
- Route orientation seed during fill: `Code/Core/Sources/DuneIICore/Scripting/Functions.swift:816`.
- Regression test: `Code/Core/Tests/DuneIICoreTests/NaiveMovementTests.swift` — `routeOrientationStableOffAxis`.

## Where it lives in the reference

`Repositories/OpenDUNE/src/script/unit.c:1296` — `Script_Unit_CalculateRoute` writes `u->orientation[0].current = u->route[0] * 32` before consuming the step. OpenDUNE's movement tick (`src/unit.c:Unit_Move`) doesn't re-overwrite orientation from continuous position during a step — it uses `Unit_SetOrientation` with a target derived from the step's compass direction, gated by `turningSpeed`.
