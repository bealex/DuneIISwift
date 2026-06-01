# AI fog of war — a debug test mode

A **debug/test-only** toggle (`GameState.aiFogOfWar`, default `false`) that gives the AI a crude fog of war so it does not attack the human's base from turn one. It is **not** a parity feature — with the flag off, behaviour is the exact stock Dune II 1.07 port and nothing in this doc applies.

## Background — why the AI attacks immediately in stock Dune II

Two visibility systems exist, and they are independent:

- **Player fog** — `MapTile.isUnveiled` plus the renderer's `showFog` flag. Player-only and (for `showFog`) render-only. The duneii "Fog of war" panel toggle defaults to off, so the human already sees the whole map; it has no effect on the AI.
- **AI vision** — the per-object `Object.seenByHouses` bitmask. A unit/structure scores 0 in the target picker (`TargetFinder.targetUnitPriority`/`targetStructurePriority`) for any house whose bit is not set. The AI has no fog of its own: in OpenDUNE the only way an AI house learns of the human's objects is that the human's objects hand themselves over.

The hand-over is faithful OpenDUNE behaviour:

- `Structure_Place` (`structure.c`, ported at `UnitCombat.structurePlace`): a structure the **player** places gets `seenByHouses |= 0xFF` — seen by *all* houses.
- `Unit_HouseUnitCount_Add` (`unit.c`, ported at `GameState.unitHouseUnitCountAdd`): a **player**-owned unit gets `seenByHouses = 0xFF` the moment it is sighted/placed.

So every building you build and every unit you make is immediately visible to the AI. (Scenario-`[STRUCTURES]` starting bases are *not* pre-revealed — `loadStructure` leaves `seenByHouses = 0` — so the AI only locks on once you build or move something.) The AI then attacks as its team scripts dictate, which feels like an instant rush.

## The toggle's model: "reveal base on first contact"

With `aiFogOfWar == true`:

1. **Player objects are no longer auto-revealed to the AI.** Instead of `0xFF`, a freshly placed/created player object is seen by the player's own house plus any AI house that has *already* found the player. This mask is `GameState.playerObjectVisibilityMask()` (returns `0xFF` when the flag is off, so the stock path is untouched).
2. **Contact reveals the base.** The only sighting path in the engine is the human's — the player's fog reveals an enemy object (`mapUnveilTile` → `unitHouseUnitCountAdd` for a unit, or the structure branch). The first time the player sights an enemy unit/structure of house *H*, `GameState.aiFogReveal(toEnemyHouse:)` flips bit *H* in `housesFoundPlayer` and back-fills every existing player unit/structure's `seenByHouses` with *H*. House *H* now sees your whole base and commits — the discover-then-rush arc.

Each AI house finds the player independently. Once found, that house behaves exactly as stock (it sees new player objects too, via the mask). The trigger is intentionally the **human making contact** ("when the player makes contact with the opponent"), matching the user's mental model; there is no separate AI-side proximity scan (the AI, blind to your base, has no reason to path toward it, so it stays quiet until you scout it out).

## State

- `GameState.aiFogOfWar: Bool = false` — the debug switch. Persisted in `SaveGame` for deterministic resume.
- `GameState.housesFoundPlayer: UInt8 = 0` — bitmask of AI houses that have made contact.

## Touch points

- `GameState.playerObjectVisibilityMask()` / `aiFogReveal(toEnemyHouse:)` — `GameState+Fog.swift`.
- `unitHouseUnitCountAdd` (`GameState+Lifecycle.swift`) — uses the mask for player units; fires `aiFogReveal` when the player sights an enemy unit.
- `mapUnveilTile` (`GameState+Fog.swift`) — fires `aiFogReveal` when the player sights an enemy structure.
- `structurePlace` (`UnitCombat.swift`) — uses the mask for a player-placed building.
- duneii: `GameModel.aiFogOfWar` + the Debug-panel toggle wire the flag into the live `Simulation.state`.

## Determinism / parity

Default off ⇒ `playerObjectVisibilityMask()` is `0xFF` and `aiFogReveal` is a no-op, so every scenario golden and the RNG draw stream are byte-identical to before. The flag draws no RNG. It is a presentation/testing aid and is out of `FeatureParity.md`'s scope.
