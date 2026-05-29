# Behavioural scenario harness

A test harness for the per-unit behaviours (movement, attack, guard, …) as they're ported from the EMC
scripts: a small **8×8 terrain** with **two units**, run through one of a few **predefined scenarios**,
assessed **visually** in a macOS app **and** verified **headlessly against OpenDUNE**. The terrain is
deterministic so a scenario is reproducible and comparable bit-for-bit.

## Layout (dependency-ordered build)

1. **`DuneIIScenarios`** (Frameworks) — the shared headless model. Terrain generation, the scenario
   definitions, building a `GameState`, and running it while capturing per-tick snapshots. No rendering,
   no app, no oracle — just the deterministic core both the app and the golden tests use.
2. **`scenariolab`** (Apps) — the macOS app. Generate/regenerate terrain, pick two unit types and a
   scenario, Run, and watch the result with a 1×–16× zoom. Renders terrain + units like `mapview`.
3. **OpenDUNE scenario golden** — an oracle mode that builds the *same* terrain + units + actions, ticks
   N frames, and dumps per-tick unit state; a Swift test reproduces it and asserts equality.

## Terrain

An 8×8 region of **sand** and **rock** (both passable; no dunes, mountains, or spice), placed at a valid
interior offset of the engine's 64×64 map (local `0:0…7:7` → map `(origin+lx, origin+ly)`; `origin ≥ 1`
so every tile is inside the scale-0 playable rectangle). The rest of the map is filled with sand.

A tile's landscape type comes from its `groundTileID`'s offset into the LANDSCAPE icon group
(`landscapeSpriteMap`): offset 0 → `normalSand`, offset 16 → `entirelyRock`. So
`sandTileID = tileIDs.landscape + 0`, `rockTileID = tileIDs.landscape + 16`. Both engines set the same
ids, so the classification (and movement cost) matches.

**Generation** is seeded: each "regenerate" makes a new sand/rock layout from an incrementing seed (a
small LCG over the 64 tiles). The saved golden scenarios pin one fixed seed, so the terrain is constant
and reproducible across our engine and the oracle.

## Scenarios (local 8×8 coords)

| kind | setup |
|------|-------|
| **moving** | unit 1 at `0:0`, moves diagonally to `7:7` |
| **closeAttack** | units 1 & 2 adjacent at centre; unit 2 attacks unit 1 until it dies |
| **farAttack** | as closeAttack but several tiles apart |
| **guarding** | unit 1 sits at `2:2` in Guard; unit 2 starts at `7:7` and moves to `2:2`; unit 1 should react |
| **moveAroundBuilding** | a 2×2 building at centre; unit 1 moves `0:0` → `7:7` around it |

Each scenario picks the unit type(s), the initial positions, and the initial action (`Move` with a
destination, `Attack` with a target, `Guard`). Until the relevant natives are ported the units won't
actually move/fire — the harness still builds and renders the setup, and the golden simply pins the
(currently static) per-tick state. As each native lands, the scenario's motion appears and the golden
captures the real trajectory.

## Snapshots

Per tick we capture each unit's `{ position (packed), orientation, hitpoints, alive }`. The golden test
asserts our per-tick sequence equals the oracle's. Visually, the app renders the latest snapshot (or
steps through them).

## Status

- [x] `DuneIIScenarios` foundation (terrain, definitions, builder, runner, snapshots). `ScenariosTests`.
- [ ] `scenariolab` macOS app.
- [ ] OpenDUNE scenario-golden oracle mode + Swift golden tests.
- [ ] Per-scenario behaviour as the movement/combat/guard natives land.
