# Gameplay feature parity — Swift engine vs OpenDUNE 1.07 (detailed)

A **feature-level** map of gameplay parity against the OpenDUNE C reference (`Repositories/OpenDUNE/src`). Presentation (rendering, audio playback, menus, mentat, intro, HUD) is **out of scope** — the engine is headless. This table is the living done/not-done record; **keep it current** (CLAUDE.md → Feature workflow step 7).

**Status legend** — ✅ Done (faithful port, tested) · ◐ Partial (core done, a sub-behaviour deferred) · ⊘ Seam (cursor/hook present, body deferred; tagged *gameplay* or *presentation*) · ✗ Missing (no implementation).

Evidence is `file` + symbol (line numbers drift; symbols don't). Audited 2026-05-31 against the `// SEAM:` markers + a source read.

---

## A. Core loop, timing, RNG

| Feature | Status | Evidence / note |
|---|---|---|
| Four-phase `tick()` Team→Unit→Structure→House | ✅ | `Simulation.tick` |
| `GameLoop_Team` cursor (5–12 tick random period) | ✅ | `Simulation.gameLoopTeam` |
| `GameLoop_Unit` 7-cursor cadence | ✅ | `Simulation.advanceUnitCadence` |
| `GameLoop_Structure` cursor (30, clamp 15–60) | ✅ | `Simulation.gameLoopStructure` |
| `GameLoop_House` cursor (900) | ✅ | `Simulation.gameLoopHouse` |
| `timerGame` / `timerGUI` two-clock | ✅ | `GameState`; game loop gated on `!paused` |
| Pause | ✅ | `Simulation.tick` early-return |
| Game speed / `Tools_AdjustToGameSpeed` | ✅ | `Simulation.adjustToGameSpeed`, `Tools` |
| Power-maintenance cursor + upkeep deduction | ✅ | `Simulation` `tickPowerMaintenance` |
| Starport-availability restock cursor | ✅ | `Simulation` `tickStarportAvailability` |
| Starport frigate-delivery cursor | ✅ | `Simulation` `tickStarport` |
| Palace special-weapon cursor | ⊘ gameplay | `Simulation` — cursor advances, **body deferred** (see §P) |
| Reinforcement cursor | ⊘ gameplay | `Simulation` — cursor advances, **body missing** (see §S) |
| House-missile countdown cursor | ⊘ gameplay | `Simulation` — cursor only (see §P) |
| Campaign-degrade cursor | ⊘ gameplay | `Simulation` — cursor only (see §Q) |
| `Random256` (3-byte feedback) | ✅ | `Random256` — bit-exact, golden-verified |
| `RandomLCG` (Borland 0x015A4E35) | ✅ | `RandomLCG` — bit-exact, golden-verified |
| RNG **draw-order** parity (the verification bar) | ✅ | per-tick draw stream byte-identical to oracle across 9 scenarios |

## B. Native primitives (the bit-exact layer)

| Primitive | Status | Evidence / note |
|---|---|---|
| `Unit_MovementTick` (speed accumulate, byte-carry step) | ✅ | `UnitMovement.movementTick` |
| `Unit_Move` (per-tick step, arrival, terrain-cross damage) | ✅ | `UnitMovement` |
| `Unit_StartMovement` (next route tile, orientation snap, enter cost) | ✅ | `UnitMovement` |
| Orientation rotate (turn speed, body+turret levels) | ✅ | `Simulation` rotation phase, `Orientation` |
| Pathfinder: direct line + CW/CCW wall-follow + smoothing | ✅ | `Pathfinder` |
| Route arrays (64-byte, `0xFF` terminator) | ✅ | `Unit`, `Pathfinder` |
| `Unit_Fire` (distance/delay, turret aim, firesTwice) | ✅ | `UnitCombat.fire` |
| `Unit_CreateBullet` (per-bullet-type dispatch) | ✅ | `UnitCombat.unitCreateBullet` |
| `Unit_Damage` (HP drain, deviation wear, fire reactions) | ✅ | `UnitMovement.damage` |
| `Unit_FindBestTargetEncoded` + priority scoring + visibility | ✅ | `TargetFinder` |
| `Unit_Deviate` / `Unit_Deviation_Decrease` | ✅ | `UnitMovement` |
| `Unit_Harvest` (gather, tile depletion, 100 cap) | ✅ | `UnitImpact.harvest` |
| `House_CalculatePowerAndCredit` | ✅ | `GameState+Lifecycle` |
| `Structure_CalculateHitpointsMax` (power-degraded cap + decay) | ✅ | `GameState+Lifecycle` |
| `Map_GetLandscapeType` | ✅ | `DefaultMapPrimitives.landscapeType` |
| `Map_ChangeSpiceAmount` | ✅ | `MapPrimitives` |
| `Map_FillCircleWithSpice` | ✅ | `MapPrimitives` |
| `Map_SearchSpice` | ✅ | `MapPrimitives` |
| `Map_FindLocationTile` (edges / air / viewport / base) | ✅ | `MapPrimitives` |
| Primitives are **replaceable protocols**, not statics | ✅ | `UnitPrimitives`/`MapPrimitives`/`HousePrimitives` |

## C. Unit script natives — `g_scriptFunctionsUnit` (64 ops, `UnitScriptRunner`)

Every opcode is routed. The eight `noOperation` entries are audio/GUI seams (presentation, out of scope).

| Op | Native | Status | Op | Native | Status |
|---|---|---|---|---|---|
| 0x00 | GetInfo | ✅ | 0x20 | GetAmount | ✅ |
| 0x01 | SetAction (+harvest guard) | ✅ | 0x21 | RandomSoldier | ✅ |
| 0x02 | DisplayText | ⊘ pres | 0x22 | Pickup (carryall) | ✅ |
| 0x03 | GetDistanceToTile | ✅ | 0x23 | CallUnitByType (summon carryall) | ✅ |
| 0x04 | StartAnimation | ✅ | 0x24 | Unknown2552 (unlink from carryall) | ✅ |
| 0x05 | SetDestination | ✅ | 0x25 | FindStructure | ✅ |
| 0x06 | GetOrientation | ✅ | 0x26 | VoicePlay | ⊘ pres |
| 0x07 | SetOrientation | ✅ | 0x27 | DisplayDestroyedText | ⊘ pres |
| 0x08 | Fire | ✅ | 0x28 | RemoveFog | ✅ |
| 0x09 | MCVDeploy | ✅ | 0x29 | SearchSpice | ✅ |
| 0x0A | SetActionDefault | ✅ | 0x2A | Harvest | ✅ |
| 0x0B | Blink | ✅ | 0x2B | (NoOp) | ⊘ pres |
| 0x0C | CalculateRoute | ✅ | 0x2C | GetLinkedUnitType | ✅ |
| 0x0D | IsEnemy | ✅ | 0x2D | GetIndexType | ✅ |
| 0x0E | ExplosionSingle | ✅ | 0x2E | DecodeIndex | ✅ |
| 0x0F | Die | ✅ | 0x2F | IsValidDestination | ✅ |
| 0x10 | Delay | ✅ | 0x30 | GetRandomTile | ✅ |
| 0x11 | IsFriendly | ✅ | 0x31 | IdleAction (foot fidget) | ✅ |
| 0x12 | ExplosionMultiple (death-hand 8) | ✅ | 0x32 | UnitCount | ✅ |
| 0x13 | SetSprite | ✅ | 0x33 | GoToClosestStructure | ✅ |
| 0x14 | TransportDeliver (carryall drop) | ✅ | 0x34 | (NoOp) | ⊘ pres |
| 0x15 | (NoOp) | ⊘ pres | 0x35 | (NoOp) | ⊘ pres |
| 0x16 | MoveToTarget (aircraft/bullet approach) | ✅ | 0x36 | Sandworm_GetBestTarget | ✅ |
| 0x17 | RandomRange | ✅ | 0x37 | Unknown2BD5 (validate var4 link) | ✅ |
| 0x18 | FindIdle | ✅ | 0x38 | GetOrientation (general) | ✅ |
| 0x19 | SetDestinationDirect | ✅ | 0x39 | (NoOp) | ⊘ pres |
| 0x1A | Stop | ✅ | 0x3A | SetTarget | ✅ |
| 0x1B | SetSpeed | ✅ | 0x3B | Unknown0288 | ✅ |
| 0x1C | FindBestTarget | ✅ | 0x3C | DelayRandom | ✅ |
| 0x1D | GetTargetPriority | ✅ | 0x3D | Rotate (turret aim) | ✅ |
| 0x1E | MoveToStructure (carryall link) | ✅ | 0x3E | GetDistanceToObject | ✅ |
| 0x1F | IsInTransport | ✅ | 0x3F | (NoOp) | ⊘ pres |

## D. Structure script natives — `g_scriptFunctionsStructure` (`StructureScriptRunner`)

| Op | Native | Status | Note |
|---|---|---|---|
| 0x00 | Delay | ✅ | |
| 0x02 | Unknown0A81 (turret-ready / linked state) | ✅ | `StructureScriptFunctions.unknown0A81` |
| 0x03 | FindUnitByType (deploy ready factory unit) | ✅ | `findUnitByType` |
| 0x04 | SetState | ✅ | `setState` |
| 0x05 | DisplayText | ⊘ pres | |
| 0x06 | Unknown11B9 | ✅ | `unknown11B9` |
| 0x07 | UnloadLinkedUnit (deploy) | ✅ | `unloadLinkedUnit` + `findFreePosition` |
| 0x08 | FindTargetUnit (turret target; 1.07 closest-unit quirk) | ✅ | `findTargetUnit` |
| 0x09 | RotateTurret | ✅ | `rotateTurret` |
| 0x0A | GetDirection | ✅ | `getDirection` |
| 0x0B | Fire (turret bullet/missile) | ✅ | `fire` |
| 0x0D | GetState | ✅ | `getState` |
| 0x0E | VoicePlay | ⊘ pres | |
| 0x0F | RemoveFogAroundTile | ✅ | `removeFogAroundTile` |
| 0x15 | RefineSpice (refinery) | ✅ | `refineSpice` |
| 0x16 | Explode | ✅ | `explode` |
| 0x17 | Destroy (soldier spawn-on-death) | ✅ | `destroy` |
| 0x01/0x0C/0x10–0x14/0x18 | general-table ops unused by structures | ✅ (NoOp) | routed to `noOperation` |

## E. Team script natives — `g_scriptFunctionsTeam` (`TeamScriptRunner`)

| Op | Native | Status | Op | Native | Status |
|---|---|---|---|---|---|
| 0x00 | Delay | ✅ | 0x08 | Load | ✅ |
| 0x01 | DisplayText | ⊘ pres | 0x09 | Load2 | ✅ |
| 0x02 | GetMembers | ✅ | 0x0A | DelayRandom | ✅ |
| 0x03 | AddClosestUnit (recruit) | ✅ | 0x0B | DisplayModalMessage | ⊘ pres |
| 0x04 | GetAverageDistance | ✅ | 0x0C | GetVariable6 | ✅ |
| 0x05 | MoveOrGuardMembers (order) | ✅ | 0x0D | GetTarget | ✅ |
| 0x06 | FindBestTarget | ✅ | 0x0E | (NoOp) | ⊘ pres |
| 0x07 | IssueAttackOrders (order) | ✅ | | | |

## F. Per-unit-type behaviour

| Unit / behaviour | Status | Evidence / note |
|---|---|---|
| Harvester: harvest → return → dock → refine → redeploy | ◐ | harvest/return/dock/**refine**/**deploy** all work (the script-VM engine-copy fix, 2026-05-31); the deployed *empty* harvester then goes STOP instead of resuming HARVEST — `HarvesterCycleTests` + insight `sim-script-vm-engine-copy` |
| Harvester death → spice spill (radius-5) | ✅ | `UnitMovement.damage` |
| Carryall: pickup / transport / deliver / summon | ✅ | natives 0x22/0x14/0x1E/0x23 (`UnitCombat`) |
| Carryall: harvester ferry (full→refinery, empty→spice) | ✅ | `UnitCombat` transport paths |
| Sandworm: movement, prey targeting, eat | ✅ | `TargetFinder.sandwormFindBestTarget`, `UnitImpact` |
| Sandworm: `blurTile` shimmer | ✅ | sim emits `FrameInfo.blurs`; render shimmer done |
| MCV: deploy → construction yard | ✅ | native 0x09 `UnitCombat.mcvDeploy` |
| Infantry/Troopers: split into pairs on damage | ✅ | `UnitMovement.damage` |
| Infantry/Troopers: missile fallback at range | ✅ | `UnitCombat.fire` |
| Deviator: mind-control gas | ✅ | `Unit_Deviate` + `Map_DeviateArea` |
| Saboteur: detonate building / capture | ✅ | `GameState+Lifecycle` |
| Missiles/rockets: homing approach | ✅ | native 0x16 `moveToTarget` |
| Ornithopter / frigate (winger flight) | ✅ | winger movement + air pass |
| Smoke on damage / wobble / idle fidget (state) | ✅ | sprite cadence (render is presentation) |

## G. Combat & area effects (detail)

| Feature | Status | Evidence / note |
|---|---|---|
| Bullet | ✅ | `unitCreateBullet` |
| Missile (rocket, homing) | ✅ | `unitCreateBullet` |
| Trooper missile | ✅ | `unitCreateBullet` |
| Sonic blast wave (self-damage hp/4+1, sonicProtection immunity) | ✅ | `UnitMovement` |
| Deviator gas missile | ✅ | `UnitMovement` / `Map_DeviateArea` |
| `Map_MakeExplosion` (distance-scaled damage + reactions) | ✅ | `UnitImpact` |
| Death-hand 17-point blast pattern | ✅ | `UnitMovement` / `UnitImpact` |
| Saboteur 500-dmg detonation | ✅ | `UnitMovement` |
| IMPACT crater classification (small/medium by damage) | ✅ | `UnitMovement` (crater **overlay** is presentation) |
| Wall destruction (HP-vs-RNG) + `Map_UpdateWall` | ✅ | `UnitImpact`, `GameState+WallSlab` |
| Explosion reactions: retaliate / team HUNT staging / harvester flee | ✅ | `UnitImpact` |
| `g_scenario` kill/score tally on a kill | ⊘ gameplay | feeds quota/score (§R) — not modelled |

## H. Unit lifecycle

| Feature | Status | Evidence |
|---|---|---|
| `Unit_Create` / `Unit_CreateWrapper` | ✅ | `UnitCombat.unitCreate` / `unitCreateWrapper` |
| `Unit_Remove` (scrub refs, free, map clear) | ✅ | `GameState+Lifecycle.unitRemove` |
| `Unit_RemovePlayer` | ✅ | `GameState+Lifecycle` |
| `Unit_Die` (explosion, removal, engine reset) | ✅ | native 0x0F `UnitImpact.die` |
| `Unit_EnterStructure` | ✅ | `GameState+Lifecycle.unitEnterStructure` |
| `Unit_UpdateMap` (occupancy + 3 fog modes) | ✅ | `GameState+Lifecycle.unitUpdateMap` |

## I. Structure build & placement

| Feature | Status | Evidence / note |
|---|---|---|
| `Structure_BuildObject` (start build, link product, countdown) | ✅ | `UnitCombat.structureBuildObject` |
| Build progress tick (cost/credit billing, HP+AI speed scaling) | ✅ | `GameState+Lifecycle.structureTickStructure` |
| `onHold` when out of money | ✅ | `structureTickStructure` |
| Completion → `.ready` | ✅ | `structureTickStructure` |
| `Structure_CancelBuild` (free + refund remainder) | ✅ | `GameState+Lifecycle.structureCancelBuild` |
| Repair branch (1.07 cost + heal +5/+3) | ✅ | `structureTickStructure` |
| Upgrade branch (bill 1/40, `upgradeTimeLeft`, Ordos HV jump) | ✅ | `structureTickStructure` |
| `Structure_IsUpgradable` gating | ✅ | `GameState+Lifecycle.structureIsUpgradable` |
| `Structure_GetBuildable` availability (campaign/tech/house/upgrade) | ✅ | `StructureBuild.buildables` |
| `Structure_IsValidBuildLocation`: bounds | ✅ | `UnitCombat.structureIsValidBuildLocation` |
| …terrain (`isValidForStructure`/`…2`, `notOnConcrete`) | ✅ | same |
| …occupancy | ✅ | same |
| …**adjacency** (touch player structure/slab/wall; CY exempt) | ✅ | **ported 2026-05-31** (was the "place anywhere" bug) |
| …missing-slab HP penalty (`−neededSlabs`) | ✅ | same |
| `Structure_Place` (corner, HP penalty, degrade, map stamp) | ✅ | `UnitCombat.structurePlace` |
| `Structure_Create` (allocate, init, place, AI full-upgrade) | ✅ | `UnitCombat.structureCreate` |
| Construction-yard place-flow + factory reset | ✅ | `UnitCombat.structurePlaceReady` |
| Slab placement (`placeSlab`) | ✅ | `GameState+WallSlab` |
| Wall placement + `structureConnectWall` | ✅ | `GameState+WallSlab` |
| Unit-factory auto-deploy (BUILD.EMC unload + free-position) | ✅ | natives 0x07/0x03 |
| Build start/complete **GUI text + sound** | ⊘ pres | |

## J. Structure mechanics

| Feature | Status | Evidence / note |
|---|---|---|
| Refinery refine (spice→credits, HP scaling, enemy ±RNG) | ✅ | native 0x15 `refineSpice` |
| Harvester dock at refinery (link, countdown, repair) | ✅ | `GameState+Lifecycle.unitEnterStructure` |
| Repair pad (linked-unit healing, cost, auto-resume) | ✅ | `structureTickStructure` repair-pad branch |
| Turret: find target / rotate / fire | ✅ | natives 0x08/0x09/0x0B |
| Silo storage + credit clamp | ✅ | `House_CalculatePowerAndCredit` + house tick |
| Starport: stock array + random restock | ✅ | `Simulation` `tickStarportAvailability` |
| Starport: frigate delivery to free starport | ✅ | `Simulation` `tickStarport` |
| **Starport: order units (CHOAM buy flow)** | ⊘ gameplay | `Structure_BuildObject` starport path returns early — you can't *order* |

## K. Structure lifecycle

| Feature | Status | Evidence |
|---|---|---|
| `Structure_Destroy` (state, credit penalty, unlink) | ✅ | `GameState+Lifecycle` |
| Enemy-destroyed refund (build cost) | ✅ | `GameState+Lifecycle` |
| `Structure_Remove` (occupancy, free, refs) | ✅ | `GameState+Lifecycle.structureRemove` |
| Soldier spawn-on-death (per-tile spawnChance) | ✅ | native 0x17 `destroy` |
| Capture / conquer (<25% HP houseID swap, recalc) | ✅ | `GameState+Lifecycle` |
| Windtrap count inc/dec | ✅ | place / destroy |
| Destruction **animation** (rubble) | ⊘ pres | |

## L. House economy

| Feature | Status | Evidence |
|---|---|---|
| Power use/production sum, damaged-plant scaling | ✅ | `House_CalculatePowerAndCredit` |
| Credit storage sum | ✅ | same |
| Credit clamp (non-player→storage; player→`max(storage,noSilo)`) | ✅ | `Simulation` house tick |
| `playerCreditsNoSilo` seed from scenario | ✅ | `ScenarioLoader.loadHouses` |
| Power maintenance upkeep | ✅ | `Simulation` `tickPowerMaintenance` |
| Attack timers (unit/sandworm/structure) decrement | ✅ | `Simulation` house tick |
| `House_EnsureHarvesterAvailable` + harvester-incoming spawn | ✅ | `UnitCombat` / `Simulation` |
| Low-power / low-credit **player hints** | ⊘ pres | |

## M. Spice & map effects

| Feature | Status | Evidence / note |
|---|---|---|
| Harvesting + tile depletion | ✅ | native 0x2A |
| `Map_ChangeSpiceAmount` (sand↔spice↔thick, edge fix) | ✅ | `MapPrimitives` |
| `Map_FillCircleWithSpice` | ✅ | `MapPrimitives` |
| Spice bloom detonation (`Map_Bloom_ExplodeSpice`) | ✅ | `UnitImpact` |
| `Map_Bloom_ExplodeSpecial` | ✅ n/a | unreachable in 1.07, intentionally unported |
| `Map_DeviateArea` | ✅ | `UnitMovement` |
| `Map_SearchSpice` | ✅ | `MapPrimitives` |
| Crater overlay + off-slab spice change on explosion | ⊘ pres | cosmetic + an RNG draw, deferred |

## N. Fog of war

| Feature | Status | Evidence |
|---|---|---|
| Binary `isUnveiled` model | ✅ | `GameState+Fog` |
| `Map_UnveilTile` (player reveal) | ✅ | `GameState+Fog` |
| `Tile_RemoveFogInRadius` | ✅ | `GameState+Fog` |
| `Unit_RemoveFog` / `Structure_RemoveFog` (per fogUncoverRadius) | ✅ | natives + `GameState+Fog` |
| Continuous reveal while moving (`Unit_UpdateMap(1)`) | ✅ | `GameState+Lifecycle` |
| `seenByHouses` per-object visibility + target gating | ✅ | `UnitCombat` / `TargetFinder` |
| Partial-fog edge model (sim) | ◐ | sim is binary; the renderer *derives* soft edges (a render concern) |

## O. AI

| Feature | Status | Evidence / note |
|---|---|---|
| `GameLoop_Team` + `isAIActive` gate | ✅ | `Simulation` |
| `Team_Create`, `[TEAMS]` loading | ✅ | `GameState+Pools` / `ScenarioLoader` |
| Full team script table (recruit/target/order/load) | ✅ | `TeamScriptRunner` (§E) |
| Team order natives reach units (move/guard/attack) | ✅ | exercised end-to-end (`TeamLoopTests`) |
| **AI structure rebuild** (`House.ai_structureRebuild`) | ⊘ gameplay | no headless consumer — destroyed AI buildings don't return |
| **AI auto-build / auto-repair** (`AI_PickNextToBuild`) | ⊘ gameplay | `structureTickStructure` AI-maintenance block is a seam — AI doesn't expand |

## P. Super-weapons / Palace

| Feature | Status | Evidence / note |
|---|---|---|
| Saboteur detonation + capture | ✅ | §K |
| Death-hand blast pattern (when a missile lands) | ✅ | §G |
| **Palace special-weapon countdown body** (death-hand launch, Fremen call, saboteur deploy) | ✗/⊘ gameplay | cursor ticks; body deferred (slice 7). The palace doesn't fire. |
| **House-missile launch** (palace → death-hand frigate) | ⊘ gameplay | cursor only |
| Fremen reinforcement call | ✗ gameplay | not implemented |

## Q. Campaign / tech / degrade

| Feature | Status | Evidence / note |
|---|---|---|
| `campaignID` effects (build-speed cap, repair heal, upgrade gating) | ✅ | wired throughout |
| Per-object `degrades` flag set (degradingChance RNG) | ✅ | `UnitCombat` / placement |
| Per-move degrade damage application (`& 3` roll) | ✅ | `UnitMovement` |
| **Campaign degrade tick body** (campaign>1 periodic degradation) | ⊘ gameplay | cursor advances, body deferred (slice 7) |

## R. Win / lose / mission / score — **the biggest gap**

| Feature | Status | Evidence / note |
|---|---|---|
| `Quota`/`creditsQuota` loaded | ✅ | `ScenarioLoader.loadHouses` |
| **Quota win check** (credits ≥ quota) | ✗ gameplay | loaded, **never checked** |
| **`WinFlags` / `LoseFlags`** load + evaluation | ✗ gameplay | not loaded, not checked |
| **`House_AreAllDead` / elimination check** | ✗ gameplay | no implementation |
| **Mission complete / failed signal** | ✗ gameplay | the game never ends |
| Score / kill tallies (destroyed/harvested allied/enemy) | ⊘ gameplay | SEAMs — feeds the score screen *and* the quota check |

## S. Reinforcements / scenario events

| Feature | Status | Evidence / note |
|---|---|---|
| Reinforcement cursor | ⊘ gameplay | `Simulation` cursor only |
| **`[REINFORCEMENTS]` parsing** | ✗ gameplay | section not read |
| **Reinforcement spawn** (timed unit/ally waves) | ✗ gameplay | no spawn |
| Other scripted scenario events | ✗ gameplay | none |

## T. Persistence

| Feature | Status | Evidence / note |
|---|---|---|
| Scenario `.INI` load (map, houses, units, structures, teams) | ✅ | `ScenarioLoader` |
| **Save game state** | ✗ | not implemented (Phase-2 tail) |
| **Load game state** | ✗ | not implemented |
| **Original `.SAV` → our format converter** | ✗ | not implemented |

## U. Scenario `.INI` loading (per section)

| Section | Status | Evidence / note |
|---|---|---|
| `[BASIC]` MapScale | ✅ | `ScenarioLoader` |
| `[MAP]` Seed → procedural terrain + spice | ✅ | `MapGenerator.createLandscape` |
| `[MAP]` **Bloom** (explicit spice-bloom tiles) | ✗ gameplay | not parsed — hand-placed blooms don't appear (procedural spice still does) |
| `[MAP]` **Field** (explicit spice-field tiles) | ✗ gameplay | not parsed |
| `[<House>]` Brain/Credits/Quota/MaxUnit | ✅ | `loadHouses` |
| `[UNITS]` | ✅ | `loadUnit` |
| `[STRUCTURES]` (`ID`, `GEN` slabs/walls) | ✅ | `loadStructure` |
| `[TEAMS]` | ✅ | `loadTeam` |
| `[CHOAM]` (starport stock seed) | ✗ gameplay | not parsed — starport stock isn't seeded from the scenario |
| `[REINFORCEMENTS]` | ✗ gameplay | not read (§S) |

## V. Audio seam (gameplay → sound)

| Feature | Status | Evidence / note |
|---|---|---|
| `SoundEvent` emission for combat fire + explosions | ✅ | `GameState.soundEvents` |
| Per-house spoken `%c` voices (acknowledge/announce) | ⊘ pres | `VoiceTable` covers only `+` combat effects |

---

## Remaining **gameplay** gaps (priority order)

Everything in the four-phase battle simulation is done and cross-engine-verified. The open *gameplay* work (presentation seams excluded):

1. **Win / lose conditions** ✗ (§R) — the single biggest gap; a match can't end. Needs quota/`WinFlags`/`LoseFlags` evaluation + `House_AreAllDead` at end of `tick()`. Pulls in the score/kill tallies.
2. **Palace super-weapons** ⊘/✗ (§P) — death-hand launch, Fremen, saboteur deploy bodies (slice 7).
3. **Scenario reinforcements** ✗ (§S) — `[REINFORCEMENTS]` parsing + timed spawns.
4. **AI base expansion** ⊘ (§O) — `ai_structureRebuild` + auto-build/repair; the AI fights with its starting base.
5. **Campaign degrade body** ⊘ (§Q) — slice-7 periodic degradation.
6. **Starport ordering** ⊘ (§J) — the CHOAM buy flow returns early.
7. **Save / load + original-save converter** ✗ (§T) — Phase-2 tail.
8. **Scenario `[MAP] Bloom`/`Field` + `[CHOAM]` not parsed** ✗ (§U) — hand-placed spice blooms/fields and the starport stock seed are dropped (procedural seed spice still generates).
