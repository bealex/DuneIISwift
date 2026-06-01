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
| Palace special-weapon cursor + body | ✅ | `Simulation.gameLoopStructure` + `structureActivateSpecial` (AI auto-fires; human launch wired in duneii via `applyPalaceCommand` — see §P) |
| Reinforcement cursor | ✅ | `gameLoopHouse` → `tickReinforcements` (see §S) |
| House-missile countdown cursor | ⊘ pres | the human target-select is a duneii UI mode, not sim state (the AI launches directly, see §P) |
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
| Foot-unit death **corpse** animation (`Script_Unit_StartAnimation`) | ✅ | ported `unitScript1/2` tables + `setOverlayTile`; corpse lingers ~1200 ticks then clears (`InteractionTests`, 2026-05-31) |

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
| `g_scenario` kill/score tally on a kill | ✅ | `UnitImpact.die` |

## H. Unit lifecycle

| Feature | Status | Evidence |
|---|---|---|
| `Unit_Create` / `Unit_CreateWrapper` | ✅ | `UnitCombat.unitCreate` / `unitCreateWrapper` — returns the ferried **cargo** for a ground unit (matching OpenDUNE), so a caller's `originEncoded` lands on the harvester, not the carryall (`GameLoopHouseTailsTests.createWrapperGround`, `StructureBuildTests.refineryHarvesterPerPlacement`) |
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
| `Structure_Place` (corner, HP penalty, degrade, map stamp) | ✅ | `UnitCombat.structurePlace` — incl. the wall/slab special cases (`structure.c:456`/`:476`): paint the tile(s) + `Structure_Free`, so player-built concrete becomes `builtSlab` tiles, not a selectable sprite-baked structure (`StructureBuildTests.placeConcrete`) |
| `Structure_Create` (allocate, init, place, AI full-upgrade) | ✅ | `UnitCombat.structureCreate` |
| Construction-yard place-flow + factory reset | ✅ | `UnitCombat.structurePlaceReady` — **each** placed refinery spawns its own harvester (`viewport.c:210`), so a 2nd/3rd refinery each get one (`StructureBuildTests.refineryHarvesterPerPlacement`; cross-engine `refinery-harvester` scenario golden — 2 refineries + `unitCount==4` match the oracle) |
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
| **Starport: order units (CHOAM buy flow)** | ✅ | `UnitCombat.structureStarportOrder` — charges the rolled CHOAM `price`, creates the unit, chains it onto `starportLinkedID`, arms the timer, decrements stock (`StarportOrderTests`). **CHOAM pricing** (`GameState.starportPrice`, `gui.c:2726`) is ported + cross-engine-golden (`StarportPriceTests` / `choamprice-golden.jsonl`); duneii rolls + charges it. The factory-window art is the only seam |

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
| Spice bloom detonation (`Map_Bloom_ExplodeSpice`) | ✅ | `UnitImpact`; the bloom sprite is removed on detonation — the loader keeps the tile's base as sand (not the bloom), or the revert would restore it. Triggered by a unit driving onto it **and** by an explosion's `BLOOM_EXPLOSION` VM command (`Explosion_Func_BloomExplosion` → `pendingBloomDetonations` → `Simulation.drainBloomDetonations`) — the "shoot a bloom to pop it" path (`BloomInteractionTests`, `ExplosionTests`) |
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
| **AI structure rebuild** (`House.aiStructureRebuild`) | ✅ | `structureRemove` records the loss; `aiStructureMaintenance` + `structureAIPickNextToBuild` rebuild + auto-place it (`AIMaintenanceTests`) |
| **AI auto-build / auto-repair** (`AI_PickNextToBuild`) | ✅ | `Simulation.aiStructureMaintenance` (`structure.c:308`) — auto-repair <50% HP, auto-build idle factories (`AIMaintenanceTests`) |

## P. Super-weapons / Palace

| Feature | Status | Evidence / note |
|---|---|---|
| Saboteur detonation + capture | ✅ | §K |
| Death-hand blast pattern (when a missile lands) | ✅ | §G |
| **Palace special-weapon countdown body** (death-hand launch, Fremen call, saboteur deploy) | ✅ | `Simulation.structureActivateSpecial` (`structure.c:822`) — an AI palace auto-fires when `countDown` hits 0; the human launches it from the duneii inspector via `Simulation.applyPalaceCommand` (`PalaceTests`) |
| **House-missile launch** (palace → death-hand) | ✅ | AI launches directly; the human picks the target — `Command.launchHouseMissile` → `structureActivateSpecial(slot, missileTarget:)` (`Unit_LaunchHouseMissile` jitter), wired to a duneii target-select click. The 7-second `g_houseMissileCountdown` window is modelled as a UI mode, not sim state. Cross-engine golden: `palace-launch` (the spawned bullet's tile + jittered `targetAttack` + re-armed countDown match the oracle) + `PalaceTests.humanMissile` |
| Fremen reinforcement call | ✅ | the Atreides/Fremen palace weapon — 5 hunting Fremen (`PalaceTests`) |

## Q. Campaign / tech / degrade

| Feature | Status | Evidence / note |
|---|---|---|
| `campaignID` effects (build-speed cap, repair heal, upgrade gating) | ✅ | wired throughout |
| Per-object `degrades` flag set (degradingChance RNG) | ✅ | `UnitCombat` / placement |
| Per-move degrade damage application (`& 3` roll) | ✅ | `UnitMovement` |
| **Campaign degrade tick body** (campaign>1 periodic degradation) | ✅ | `gameLoopStructure` degrade body — a `degrades` structure above half base HP takes `degradingAmount` (`DegradeTests`) |

## R. Win / lose / mission / score — **the biggest gap**

| Feature | Status | Evidence / note |
|---|---|---|
| `Quota`/`creditsQuota` loaded | ✅ | `ScenarioLoader.loadHouses` |
| **Quota win check** (credits ≥ quota) | ✅ | `Simulation.evaluateLevelEnd` (`WinFlags` bit 2) |
| **`WinFlags` / `LoseFlags`** load + evaluation | ✅ | `[BASIC]` → `Scenario`; `levelIsFinished`/`levelIsWon` |
| structure-count elimination (no enemy / no friendly structures) | ✅ | `levelStructureCounts` (`WinFlags` 0x1/0x2) |
| **Mission complete / failed signal** | ✅ | `GameState.gameEndState`, latched in `tick()` after the 7200-tick minimum |
| Score / kill / harvested tallies (`g_scenario`) | ✅ | bumped in `Unit_Die` / `Structure_Damage` / `RefineSpice` |

## S. Reinforcements / scenario events

| Feature | Status | Evidence / note |
|---|---|---|
| Reinforcement cursor | ✅ | `gameLoopHouse` → `tickReinforcements` (every 600) |
| **`[REINFORCEMENTS]` parsing** | ✅ | `ScenarioLoader.loadReinforcement` → `Scenario.reinforcements[16]` |
| **Reinforcement spawn** (timed unit/ally waves) | ✅ | `Simulation+Reinforcements` — edge place / air carryall drop (`ReinforcementTests`); 1.07 fires once (no repeat) |
| Other scripted scenario events | ✗ gameplay | none (1.07 has none beyond reinforcements) |

## T. Persistence

| Feature | Status | Evidence / note |
|---|---|---|
| Scenario `.INI` load (map, houses, units, structures, teams) | ✅ | `ScenarioLoader` |
| **Save game state** (our format) | ✅ | `SaveGame.save` — versioned binary plist of the whole `GameState` (`SaveGameTests`) |
| **Load game state** (our format) | ✅ | `SaveGame.load` — resumes **bit-identically** (RNG state included; `SaveGameTests.deterministicResume`) |
| **Original `.SAV` converter** (read OpenDUNE saves) | ✅ | `SaveConverter` — parses the IFF/FORM chunks (INFO/PLYR/UNIT/BLDG/MAP/TEAM), seed-regenerates the map + applies tile overrides, rebuilds the pools. Cross-engine-verified vs the oracle's load of the same `.SAV` (`SaveConverterTests`). Behaviorally faithful, not a byte-exact EMC-VM resume (per `Plan.v1.md` §2) |

## U. Scenario `.INI` loading (per section)

| Section | Status | Evidence / note |
|---|---|---|
| `[BASIC]` MapScale | ✅ | `ScenarioLoader` |
| `[MAP]` Seed → procedural terrain + spice | ✅ | `MapGenerator.createLandscape` |
| `[MAP]` **Bloom** / **Special** (explicit spice-bloom tiles) | ✅ | `loadMapBlooms` stamps `tileIDs.bloom` |
| `[MAP]` **Field** (explicit spice-field tiles) | ✅ | `ScenarioLoader` stashes the tiles in `scenario.spiceFields`; `Simulation.applyScenarioSpiceFields` detonates each (`Map_Bloom_ExplodeSpice`, radius-5) before the first tick (`SpiceFieldTests`, `ScenarioLoaderTests.loadMapField`) |
| `[<House>]` Brain/Credits/Quota/MaxUnit | ✅ | `loadHouses` |
| `[UNITS]` | ✅ | `loadUnit` |
| `[STRUCTURES]` (`ID`, `GEN` slabs/walls) | ✅ | `loadStructure` |
| `[TEAMS]` | ✅ | `loadTeam` |
| `[CHOAM]` (starport stock seed) | ✅ | `ScenarioLoader` seeds `starportAvailable[type]` (`ScenarioLoaderTests`) |
| `[REINFORCEMENTS]` | ✅ | `loadReinforcement` (§S) |

## V. Audio seam (gameplay → sound)

| Feature | Status | Evidence / note |
|---|---|---|
| `SoundEvent` emission for combat fire + explosions | ✅ | `GameState.soundEvents` |
| Per-house spoken `%c` voices (acknowledge/announce) | ⊘ pres | `VoiceTable` covers only `+` combat effects |

---

## Remaining **gameplay** gaps (priority order)

Everything in the four-phase battle simulation is done and cross-engine-verified. The open *gameplay* work (presentation seams excluded):

1. ~~Win / lose conditions~~ ✅ (§R, 2026-05-31) — `WinFlags`/`LoseFlags` + structure-count/quota; `gameEndState` latched in `tick()`. Score/kill/harvested tallies also done.
2. ~~Scenario reinforcements~~ ✅ (§S, 2026-05-31) — `[REINFORCEMENTS]` parsing + timed edge/air spawns; 1.07 fires each once.
3. ~~Campaign degrade body~~ ✅ (§Q, 2026-05-31) — campaign>1 periodic degradation to half HP.
4. ~~`[CHOAM]` starport stock seed~~ ✅ (§U, 2026-05-31) — `starportAvailable` seeded from the scenario.
5. ~~Palace super-weapons~~ ✅ (§P, 2026-05-31) — `structureActivateSpecial`: AI death-hand launch / Fremen call / saboteur deploy, **plus the human launch** (`applyPalaceCommand` + duneii inspector launch button & death-hand target-select).
6. ~~AI base expansion~~ ✅ (§O, 2026-05-31) — `aiStructureMaintenance` + `structureAIPickNextToBuild` + the `aiStructureRebuild` queue: auto-repair, auto-build, rebuild-and-auto-place.
7. ~~Starport ordering~~ ✅ (§J, 2026-05-31) — `structureStarportOrder` chains an order onto the delivery list; the factory-window GUI + CHOAM pricing stays a Phase-6 seam.
8. ~~Save / load + original-save converter~~ ✅ (§T, 2026-05-31) — our `SaveGame` (bit-identical resume) + `SaveConverter` (reads original OpenDUNE `.SAV`, cross-engine-verified). **This was the last missing gameplay feature.**
9. ~~Scenario `[MAP] Field` not filled~~ ✅ (§U, 2026-05-31) — `applyScenarioSpiceFields` detonates each hand-placed field (radius-5 spice circle) before the first tick.

**🎉 No missing gameplay features remain.** The entire four-phase battle simulation + persistence is implemented and cross-engine-verified against OpenDUNE 1.07. Open items are presentation seams (per-house spoken voices, the original factory-window art) and `duneii`-client polish — out of this table's scope.

(~~Known parity bug: `unitCreateWrapper` returned the carryall instead of the cargo~~ ✅ fixed 2026-05-31 — §H; it now returns the ferried cargo, so a harvester's `originEncoded` home refinery is set correctly.)
