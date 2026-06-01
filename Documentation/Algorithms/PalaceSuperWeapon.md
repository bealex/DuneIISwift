# Palace super-weapon — AI auto-fire and human launch

Reference: `Structure_ActivateSpecial` (`src/structure.c:822`), the per-palace countdown in `GameLoop_Structure` (`structure.c:106`), and `Unit_LaunchHouseMissile` (`src/unit.c:2581`).

Each house has one special weapon (`HouseInfo[house].specialWeapon`) and a recharge period (`specialCountDown`):

- **1 = MISSILE** — Harkonnen / Sardaukar: the death-hand. Spawns an off-map `missileHouse` carrier (one `Random256` orientation), then fires a `missileHouse` bullet (damage `0x1F4`) from the palace tile at a target, jittered ±160 (`Tile_MoveByRandom(target, 160, false)`) — deliberately inaccurate.
- **2 = FREMEN** — Atreides / Fremen: spawns 5 Fremen `trooper`/`troopers` (one LCG orientation per spawn selects which) around a random map tile, each set to HUNT.
- **3 = SABOTEUR** — Ordos / Mercenary: spawns one saboteur on a free tile next to the palace, set to SABOTAGE (no free tile ⇒ `countDown = 1`, retry next palace tick).

## Countdown and who fires

Every palace tick (`gameLoopStructure`, when the palace cursor is due) the countdown decrements toward 0. A fresh palace starts at 0, so it is ready on its first palace tick and every `specialCountDown` ticks after firing (firing re-arms `countDown = specialCountDown`).

- **AI palace** (`!human && isAIActive`): fires automatically when `countDown == 0` — `structureActivateSpecial(slot)` with no explicit target. The MISSILE branch scans for the first non-allied, non-slab/wall structure and launches there.
- **Human palace**: the countdown still ticks, but the engine does **not** auto-fire. The player triggers the launch from the UI when the palace is ready. (`Code/Frameworks/DuneIISimulation/Simulation.swift` gates the auto-fire to `!human`.)

## Human launch path (this slice)

The launch is one command per fire (the duneii target-select window is purely UI; no `g_houseMissileCountdown` sim state is modelled):

- **No-target weapons** (FREMEN, SABOTEUR): `Command.activateSuperWeapon(structure:)` → `structureActivateSpecial(slot)`. Same spawn the AI runs (the body is house-driven, not AI-specific).
- **Death-hand** (MISSILE): `Command.launchHouseMissile(structure:, tile:)` → `structureActivateSpecial(slot, missileTarget: tile)`. Identical to the AI MISSILE fire except the target is the player's clicked tile instead of the first-enemy-structure scan. Both create+free the carrier and jitter ±160, matching `Unit_LaunchHouseMissile`.

`Simulation.applyPalaceCommand(_:)` consumes these two commands and **gates** the fire to a ready (`countDown == 0`), `used`, player-owned palace (so a stale UI click can't fire early, fire twice, or fire a non-palace / enemy structure). It returns `false` for any other command, so the caller (duneii's command drain) routes everything else through `UnitOrders`.

### duneii UI

The selection inspector, for a selected ready player palace, shows a **Launch** button. For a MISSILE house it arms a target-select cursor (`PendingOrder` reused from the attack crosshair) and the next map click issues `launchHouseMissile`; for FREMEN/SABOTEUR the button issues `activateSuperWeapon` immediately. `GameModel.advance` calls `sim.applyPalaceCommand(c)` first and falls back to `UnitOrders.apply` when it returns `false`.

## Parity / determinism

The sim core is unchanged for the AI (the new `missileTarget` parameter defaults to `nil`), so all goldens stay byte-identical. The human launch draws exactly what the AI launch draws (one `Random256` carrier orientation + the two-draw `Tile_MoveByRandom` jitter for MISSILE), so it is faithful to `Structure_ActivateSpecial`.
