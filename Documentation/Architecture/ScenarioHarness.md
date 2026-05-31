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

Beyond these golden-parity kinds, the harness (`DuneIIScenarios.ScenarioKind`) also carries **demo / visual** scenarios that exercise later subsystems without an oracle pin: `deviate`, `attackStructure` (golden-pinned), `turretDefense`, and the `tickStructure` economy trio `factoryProduce` / `repairBuilding` / `upgradeBuilding` (a factory builds → READY, a building self-repairs, a building upgrades). The economy ones set the player's no-silo credit allowance and suspend the structure's placement-animation script (`settle`) so the production state isn't clobbered — see `DuneIIScenarios/CLAUDE.md`.

### Lab visual affordances (`scenariolab`)

The `scenariolab` app adds two cues (a dead unit/structure otherwise just stops being drawn):

- **Real damage/death/destruction visuals.** The **Explosion subsystem** (`DuneIIWorld` `Explosion.swift` + `GameState+Explosion.swift`, a faithful port of OpenDUNE `src/explosion.c`) drives the actual impact/death/building-destruction sprite animations, plus a smoke cloud over damaged-but-alive vehicles (the `.isSmoking` flag), and the **infantry walk cycle** (the `tickUnknown5` `spriteOffset` animation in `gameLoopUnit`). Unit death runs the real DIE branch (`ExplosionSingle`/`StartAnimation` → `Die` → `Unit_Remove`). `Map_MakeExplosion` starts explosions (RNG-free, golden-neutral); the per-tick `explosionTick` (which draws RNG) is **gated** — off for the goldens (matching the oracle harness, which never ticks explosions), on for the lab via `Simulation(tickExplosions:)`. The renderer reuses the already-loaded UNITS SHPs. See `Documentation/Algorithms/Explosion.md`.
- **Finished marker + grace.** `ScenarioWorld.outcome()` (`ScenarioOutcome.swift`) declares each kind's natural endpoint (a unit arrives, a building is destroyed/built/repaired/upgraded, a combatant dies, a unit is deviated). When it first reports `.finished(label)` the scene shows a "✓ <label>" banner, then keeps ticking a **5-second grace period** (`ScenarioScene.finishGraceSeconds`) so death/destruction explosions + animations play out, then auto-pauses. A lab affordance, **not** a simulation victory/game-over model.

The walk animation is golden-verified: the **`trooper`** scenario (a foot trooper walking 400 ticks) is a full per-tick match vs the oracle, and the unit dump now includes **`spriteOffset`** (so every scenario verifies the animation frame; 0 for non-foot units).

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
- [x] Structure-placement command — `--parity-place=<cyIndex>,<objectType>,<tile>` (oracle `Scen_BuildPlace`)
  + the `place:` specs (Swift `structureBuildObject` + `structurePlaceReady`). A CY builds + the player places
  a structure; exercises the per-refinery harvester spawn (`refinery-harvester` golden). Headless caveats:
  the build is force-completed (no countdown); the oracle replicates only the headless state-setup (the full
  `Structure_BuildObject`/`House_CalculatePowerAndCredit` player-house `GUI_DisplayText` needs strings the
  harness doesn't load — keep the player **powered** so the underpowered-warning text never fires).
- [x] Oracle scenario parity mode (`--parity-scenario` in `parity.c`, self-contained: pools + ICON.MAP +
  `UNIT.EMC` + `Map_CreateLandscape` + `[UNITS]` + command replay + per-tick dump) + golden test
  (`ScenarioGoldenTests`, frame-0 parity for the moving scenario).
- [x] Per-tick trajectory comparison + 11 scenarios (move/move-trike/guard/attack-close/attack-rocket/attack-structure/trooper/economy/teams/missile-duel/wall-destruction/slab-indestructible).
- [x] **Structures + houses in the golden** — the oracle dump is now `Scen_DumpState` (`{tick, houses, structures, units}`, reusing `Parity_DumpHouses`/`Parity_DumpStructures`); the scenario mode loads `[STRUCTURES]` (`Scen_LoadStructure` + `Structure_Create` placement + `BUILD.EMC`); `ScenarioGoldenTests` compares structures (hp/state/linkedID) per tick. `attack-structure` (a tank vs an Ordos windtrap) matches the **full 400 ticks** — including the bullet-impact `Structure_Damage` (200→175). **This golden immediately found a real bug:** structures must store the tile *corner*, not the centred sub-tile (`Structure_Place`: `position &= 0xFF00`) — see insight `world-structure-corner-position`.
- [x] **House-economy golden (`economy`)** — a new **`[HOUSES]`** scenario section activates a house (`Scen_LoadHouse`/`House_Allocate` on the oracle; `loadScenario` + `houseAllocate` on our side) with starting credits, and both sides `House_CalculatePowerAndCredit` after load. `economy.ini` (an Ordos windtrap+silo base, no units) gives a **full 60-tick** house-aggregate match — `credits` 2000 → clamp-to-storage 1000 → power-maintenance 999, `powerProduction` 100, `powerUsage` 5, `creditsStorage` 1000 — validating `House_CalculatePowerAndCredit` + the `GameLoop_House` credit clamp + power upkeep cross-engine. Scenarios without `[HOUSES]` are unchanged (no active houses ⇒ both house dumps empty). `ScenarioGoldenTests` now compares `houses` (`credits/creditsStorage/powerProduction/powerUsage`) per tick.
- [x] **Tier-2a structure decision-trace** — the oracle's `--parity-script-trace` + `--parity-script-structure=<idx>` emits one line per executed opcode (`pc/op/param/delay/SP/FP/return/current`) for one structure (now wired into the **scenario** mode, not just savegame parity). Our `StructureScriptRunner` emits the identical line via an injected `StructureScriptTracer` (`ScriptTraceLine.decode` — the same opcode/flag decode, pre-execution `SP`/`FP`/`delay`/`return`); `StructureTraceTests` diffs line-by-line. The `attack-structure` windtrap (index 0) matches the oracle's 24-opcode trace exactly — placement-animation subroutine (`FP` 17↔14), `RemoveFog`/`GetState`/`SetState`, settle into `Delay(120)`. Proves the EMC execution is opcode-identical (not just state-identical) + localizes any divergence to the exact PC. Fixture `attack-structure-struct0-trace.txt`, regenerated by `gen-scenario-goldens.sh`.
- [x] **Map-tile goldens (wall/slab destruction)** — walls/slabs aren't in the structure find-array, so their state lives in the map tile. A new **`[DUMPTILES]`** section (each value a packed tile) makes `Scen_DumpState` emit `"tiles":[{packed,ground,overlay,lst}]` per tick; `ScenarioGoldenTests` decodes + compares each cell's **`groundTileID`** (the unambiguous observable — `overlay` carries the fog veil with a latent off-by-one, insight `world-fog-veil-overlay-off-by-one`). **`wall-destruction`** (seed 42): a tank's 25-dmg bullet's `Random_256` roll destroys the 50-HP wall at tick 67 — `Map_MakeExplosion`'s wall branch (`map.c:503`, deterministic when blast HP ≥ wall HP, else a roll) + the ported `Map_UpdateWall` revert the ground sprite to the base terrain; it rides the RNG-stream golden (the destroy draw aligns). **`slab-indestructible`** (explosion VM **ticked** via a new `[BASIC] TickExplosions=1` flag → `Explosion_Tick` in the scenario loop): a built concrete slab **is** destructible, but only by an explosion carrying the `TILE_DAMAGE` command (`Explosion_Func_TileDamage`, `explosion.c:49`), which lives on the larger explosion types (IMPACT_LARGE/EXPLODE). A tank's bullet is `EXPLOSION_IMPACT_SMALL` (no `TILE_DAMAGE`), so the slab ground stays even with explosions ticking — this golden proves that. The actual slab-revert under a `TILE_DAMAGE` explosion is verified RNG-free by `ExplosionTests` (a scattering rocket can't reliably hit an exact tile + the harness fires once, so the destruction itself isn't a scenario golden).
- [ ] **Even-better harness (next, per `ParityHarness.md`):** broaden the decision-trace (a unit trace via `--parity-script-unit`; a structure that runs its **death** branch) and **Tier-3i semantic event-trace alignment** (RNG-robust): both engines emit `(tick, event, entity, payload)` for fire/damage/dock/refine/destroy, aligned tolerant-on-tick.

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
