# Explosion subsystem

A faithful port of OpenDUNE's `src/explosion.c` + `src/table/explosion.c` (`src/explosion.h` for the
structs/enums). Explosions are the short, purely-visual sprite animations played at a tile for impacts,
unit deaths, and building destruction — driven by a tiny command VM (set-sprite / set-timeout / move /
stop, plus a few side-effecting commands). They live in `GameState.explosions` (a 32-slot pool, the
`EXPLOSION_MAX` cap) and are advanced by `explosionTick()`.

## Model (`DuneIIWorld/Model/Explosion.swift`)

- `Explosion` — `timeOut`, `houseID`, `current` (cursor), `spriteID`, `position: Tile32`, `tableIndex`
  (the `ExplosionType` whose command list it runs; `-1` = free slot, mirroring C's `commands == NULL`),
  `active`.
- `ExplosionCommand` (10 cases, `explosion.h` order) + `ExplosionCommandStruct` `(command, parameter:
  Int16)` — `Int16` so `MOVE_Y_POSITION -80` is natural.
- `ExplosionType` (20 cases, `explosion.h` order; `structure = 14` is the building-destruction one).
- `ExplosionTables.commands` — all 20 command lists from `table/explosion.c`, verbatim.

## Logic (`DuneIIWorld/State/GameState+Explosion.swift`)

- `explosionStart(type:position:houseID:)` (`explosion.c:282`) — bounds-check, `explosionStopAtPosition`
  the tile, take the first free slot, init (`timeOut = timerGUI`, `current = 0`, set the tile's
  `hasExplosion`), reset `explosionTimer = 0`. **Draws no RNG.**
- `explosionTick()` (`explosion.c:318`) — the `explosionTimer > timerGUI` early-out (`+= 10000`),
  per-slot due check (`timeOut <= timerGUI`), execute **one** command, advance `current`, then track the
  soonest next `timeOut` into `explosionTimer`. Handlers: `SET_SPRITE`, `SET_TIMEOUT`,
  `SET_RANDOM_TIMEOUT` (`randomLCG.range(0, v)`), `MOVE_Y_POSITION`, `STOP` (clear `hasExplosion`, free
  the slot).
- `explosionStopAtPosition(packed)` (`explosion.c:252`).

### Seams (not needed for the unit-death / building-destruction / smoke visuals)
- `TILE_DAMAGE` (`explosion.c:49`) — crater overlay + `Map_ChangeSpiceAmount(-1)` + bloom detonation, and
  its `Random_256() & 1` draw. Documented seam (no-op): craters need the crater icon-map + the spice/bloom
  primitives, which aren't ported; it is cosmetic + gated off for goldens (see below).
- `PLAY_VOICE` (audio), `SCREEN_SHAKE` (video), `SET_ANIMATION` (only the two crash explosions use it —
  needs `g_table_animation_map`). No-ops.
- `BLOOM_EXPLOSION` (`Explosion_Func_BloomExplosion`, `explosion.c:157`) is **wired**: when the explosion's
  tile is still the bloom tile it records the packed tile in `state.pendingBloomDetonations` (the VM is
  World-layer; `Map_Bloom_ExplodeSpice` is a Simulation primitive — spice-fill + tremor), which the loop
  drains right after `explosionTick` (`Simulation.drainBloomDetonations`). This is the "shoot a bloom to
  pop it" path — the impact explosions all carry the command. Only realized on the explosion-ticking
  (visual-app) path, so it is golden-neutral. (`ExplosionTests`, `BloomInteractionTests`.)

## Triggering + the parity gate

`Map_MakeExplosion` (our `UnitImpact.swift`) already runs in the deterministic path (bullet impact, unit
death, the structure `explode` native → `EXPLOSION_STRUCTURE`); it now ends with `explosionStart(...)`.
Because `explosionStart` draws no RNG, this is **golden-neutral** — and it matches the oracle, whose
`Map_MakeExplosion` also calls `Explosion_Start` even in the scenario parity harness.

`explosionTick()` **does** draw RNG (`SET_RANDOM_TIMEOUT` → LCG; the `TILE_DAMAGE` seam would draw
`Random_256`). The OpenDUNE scenario parity harness (`src/parity.c`) runs only the four `GameLoop_*`
phases — it **never** ticks explosions — so ticking on our side would desync the goldens (e.g.
`attack-structure` destroys a windtrap → an `EXPLOSION_STRUCTURE` → `SET_RANDOM_TIMEOUT` LCG draw).
Therefore the tick is **gated**: `Simulation(tickExplosions:)` defaults `false` (goldens, matching the
oracle) and `scenariolab` sets it `true`. Explosions are a faithful but lab-only presentation layer; a
future Tier-3 upgrade (tick explosions in the oracle harness too, with aligned RNG) can drop the gate —
which is why the LCG draw is ported exactly.

## Rendering (`scenariolab`)

The explosion `spriteID`s (153/154/183/184/188–192/198–222/…) are global sprite indices that fall in the
`UNITS1.SHP`/`UNITS2.SHP`/`UNITS.SHP` ranges the lab already loads (`Sprites_Init`), so the existing
`ScenarioImageBuilder.globalSprite(_:)` maps them with no new asset. The renderer draws each active
explosion's current `spriteID` at its `position` each frame; the sim drives the frame changes via
`explosionTick`. Damaged-but-alive vehicles (the already-set `.isSmoking` flag) get a cycling smoke
sprite (`UNITS1` smoke frames) drawn above them — a lab approximation of the runtime smoke draw.
