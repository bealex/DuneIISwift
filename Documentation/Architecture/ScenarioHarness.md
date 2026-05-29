# Behavioural scenario harness

A test harness for the per-unit behaviours (movement, attack, guard, …) as they're ported from the EMC
scripts: a **real scenario `.INI`** loaded by **both** our engine and the OpenDUNE oracle, with the
specific behaviour driven by **simulated user input** (select a unit, order a move/attack), then run and
**verified per-tick against the oracle**. Built on the real machinery (scenario loading, `createLandscape`
terrain, the command/input pipeline) so the harness doubles as the integration-test bed we need anyway.

## Approach (decided)

- **Shared scenario file.** One committed `.INI` per scenario (standard Dune II format). Our engine loads
  it via `GameState.loadScenario`; the oracle loads it via `Scenario_Load` (a new parity mode that does
  the game's file/sprite/pool init). Same file → comparable.
- **Terrain = `[MAP] Seed → Map_CreateLandscape`.** The real generator, so the terrain has natural
  partial sand/rock transition tiles (not a tile-by-tile pick). We already reproduce it bit-exactly.
- **Actions via simulated user input.** The `.INI` places the units (+ an initial state like Guard); the
  scenario's behaviour (move-to-tile, attack-target) is issued as **`Command`s** — select unit, order —
  through a command/input-application path in the sim, mirrored by input replay in the oracle. This is a
  new subsystem (built now; needed for interactive testing generally).
- **Per-tick golden.** Both engines run N ticks from the same scenario + command stream and dump each
  unit's `{ position, orientation, hitpoints, alive }` per tick; a test asserts equality (raised
  tick-by-tick as the movement/combat/guard natives land).

## Scenarios

Bootstrap with **one** scenario end-to-end (moving), then add: close/far attack, guarding,
move-around-building. Each = a `.INI` (terrain seed + unit placements) + a `Command` sequence:

| kind | placements (.INI) | commands |
|------|-------------------|----------|
| moving | unit 1 near a corner | select unit 1, move to the far tile |
| closeAttack | units 1 & 2 adjacent (enemy houses) | select unit 2, attack unit 1 |
| farAttack | as close but apart | select unit 2, attack unit 1 |
| guarding | unit 1 (Guard) + unit 2 | select unit 2, move toward unit 1 |
| moveAroundBuilding | a building + unit 1 | select unit 1, move past the building |

## Pieces (dependency order)

1. **Bootstrap `.INI`** + our `loadScenario` of it (terrain via `createLandscape`, units placed). ← first.
2. **Command pipeline** — `Command` application in `DuneIISimulation` (select, order move/attack), the
   port of OpenDUNE's click→order path; matching input replay on the oracle side.
3. **Oracle parity mode** — `Scenario_Load` of the custom `.INI` + replay the command stream + tick + dump.
4. **Golden test** — our run vs the oracle's per-tick dump; the `scenariolab` app renders the same.

## App

`scenariolab` (macOS, 1×–16× zoom) loads the scenario, lets you pick the scenario/units, runs it, and
renders terrain + units for visual assessment — the same scenario the golden verifies.

## Status

- [x] (interim) synthetic terrain/builder + app + foundation `DuneIIScenarios` + `scenariolab`.
- [x] Bootstrap `.INI` + our `loadScenario` (`BootstrapScenarioTests`).
- [x] Command pipeline — `Command` (Contracts) + `UnitOrders` (sim) + the oracle's `Scen_Order` replay.
- [x] Oracle scenario parity mode (`--parity-scenario` in `parity.c`, self-contained: pools + ICON.MAP +
  `UNIT.EMC` + `Map_CreateLandscape` + `[UNITS]` + command replay + per-tick dump) + golden test
  (`ScenarioGoldenTests`, frame-0 parity for the moving scenario).
- [ ] Per-tick trajectory comparison + the other scenarios, as the movement/combat/guard natives land.

**Oracle env note — two scenario modes.** OpenDUNE's full game init (GFX/sprites/strings) and the unit
movement/placement path (`Game_Prepare`/`Unit_UpdateMap`) do **not** run in the agent's headless sandbox.
So `parity.c` has two scenario modes:

- `--parity-scenario=<id>` — **self-contained**, dispatched right after `File_Init` (pools + ICON.MAP +
  `UNIT.EMC`, no GFX). Runs headless, but units don't move (no `Game_Prepare`): it gives the **frame-0 /
  setup parity** dump, which the in-sandbox golden uses.
- `--parity-scenario-run=<id>` — the **real** `Game_LoadScenario` + `GameLoop` trajectory (units actually
  move). Needs the full init, so **run it outside the sandbox** (a display-capable macOS terminal).

Both load the custom `.INI` by placing `bootstrap.ini` as `SCENH<id>.INI` in a data dir that also has the
install PAKs, and replay the same `--parity-cmd` stream. **Generate the trajectory fixtures with
`Scripts/gen-scenario-goldens.sh [INSTALL_DIR]`** (outside the sandbox); it builds the oracle, stages the
data dir, runs each scenario, and writes `*-golden.jsonl` under `Tests/ScenariosTests/Fixtures/`. Then
re-run the Swift golden and raise its `comparedTicks`.
