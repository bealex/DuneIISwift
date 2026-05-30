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
- [x] Per-tick trajectory comparison + 6 scenarios (move/move-trike/guard/attack-close/attack-rocket/attack-structure).
- [x] **Structures + houses in the golden** — the oracle dump is now `Scen_DumpState` (`{tick, houses, structures, units}`, reusing `Parity_DumpHouses`/`Parity_DumpStructures`); the scenario mode loads `[STRUCTURES]` (`Scen_LoadStructure` + `Structure_Create` placement + `BUILD.EMC`); `ScenarioGoldenTests` compares structures (hp/state/linkedID) per tick. `attack-structure` (a tank vs an Ordos windtrap) matches the **full 400 ticks** — including the bullet-impact `Structure_Damage` (200→175). **This golden immediately found a real bug:** structures must store the tile *corner*, not the centred sub-tile (`Structure_Place`: `position &= 0xFF00`) — see insight `world-structure-corner-position`.
- [ ] **Even-better harness (next, per `ParityHarness.md`):** **Tier-2a structure decision-trace** — the oracle already emits a per-opcode trace (`pc/op/param/SP/FP/return`) for a structure index (`g_parityScriptTraceStructureIndex`, `--parity-script-trace`); emit the same from our `StructureScriptRunner` and compare opcode-by-opcode (directly tests "matches EMC exactly", localizes any divergence to the exact PC). Then **Tier-3i semantic event-trace alignment** (RNG-robust): both engines emit `(tick, event, entity, payload)` for fire/damage/dock/refine/destroy, aligned tolerant-on-tick.

**Oracle mode (`--parity-scenario=<id>`) — self-contained + headless, with real movement.** OpenDUNE's
full game init (GFX/sprites/strings) and `Game_Prepare` don't run headless, so the mode is dispatched
right after `File_Init` and does a **minimal init** instead: pools + the `ICON.MAP` tile-id bases +
`UNIT.EMC`, then loads the custom `SCEN<H><id>.INI` (terrain from `[MAP] Seed → Map_CreateLandscape`),
places each unit on the map (`Unit_UpdateMap`, the bit of `Game_Prepare` movement needs), pins
`gameSpeed`, **points `g_viewportPosition` at the region** (else `GameLoop_Unit` throttles an
off-viewport unit's script to 3 opcodes/tick and it never sets up a move), replays the `--parity-cmd`
stream (the same `gui/viewport.c` order our `UnitOrders` mirrors), ticks `GameLoop_*`, and dumps per-tick
unit state. **Units actually move** — e.g. a tank ordered `(16,16)→(40,40)` rotates then steps
diagonally. So the committed `*-golden.jsonl` carry the real trajectory.

**macOS gotcha:** a relinked binary's stale code signature makes the kernel SIGKILL it ("killed", no
output); `codesign --force --sign - bin/opendune` after building fixes it (the script does this).

**Generate fixtures with `Scripts/gen-scenario-goldens.sh [INSTALL_DIR]`** (runs anywhere — no display
needed): builds + re-signs the oracle, stages the data dir (install PAKs + each `.INI` as `SCENH<id>.INI`),
runs every scenario, writes `*-golden.jsonl` under `Tests/ScenariosTests/Fixtures/`. Then re-run the
Swift golden and raise its `comparedTicks` as our `GameLoop_Unit` learns to run scripts + move.
