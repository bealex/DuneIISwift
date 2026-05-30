# Structure scripts + `GameLoop_Structure`

Design of record for the structure script subsystem: bridging `BUILD.EMC` into a structure `ScriptInfo`, running structure EMC scripts each tick (`GameLoop_Structure`), and closing the structure death path. Source of truth: OpenDUNE `src/structure.c`, `src/script/structure.c`, `src/script/script.c`.

## Same VM, different table + script

A structure runs the *same* EMC interpreter as a unit (`ScriptInterpreter` / `Script_Run`, one opcode per call). Only two things differ (`script.c`):

- **The program.** Structures share one `ScriptInfo` bridged from `BUILD.EMC` (`g_scriptStructure`, loaded once at startup), as units share `UNIT.EMC`. The per-type entry is `offsets[structureType]` (the `ORDR` chunk), reached by `Script_Load(engine, type)` — identical mechanics to units.
- **The native table.** Op-14 `FUNCTION n` indexes `g_scriptFunctionsStructure` (the `Script_Structure_*` natives), not the unit table. Our `StructureScriptRunner.dispatch` is the structure analog of `UnitScriptRunner.dispatch`.

Each structure carries its own `ScriptEngine` (`s.o.script`) — PC, stack, frame pointer, `variables[0…4]`, `delay`. `variables[0]` is the **death flag** (0 alive, 1 dying).

## `GameLoop_Structure` (`structure.c:53`)

Runs every tick; throttles sub-activities with next-due cursors (`StructureTickCursors` in `GameState`, the structure analog of `UnitTickCursors`):

| activity   | interval (ticks)                              | status |
|------------|-----------------------------------------------|--------|
| degrade    | `AdjustToGameSpeed(10800,5400,21600, inv)`, campaign>1 | SEAM (AI/campaign) |
| structure  | `AdjustToGameSpeed(30,15,60, inv)`            | SEAM (BUILD/REPAIR/factory state machine — the economy/production slice) |
| script     | `+5`                                          | **live** |
| palace     | `+60`                                         | SEAM (special-weapon countdown) |

Per structure (via `Structure_Find`), when the **script** cursor fires:

```
if script.delay != 0:        script.delay -= 1
else if Script_IsLoaded:     run Script_Run up to 3×   (3 opcodes/script-tick)
else:                        Script_Reset; Script_Load(type)   // (re)load the type's script
```

The `else` (not-loaded) branch is how a structure's script starts **and** restarts: a freshly placed structure (or one whose script erred / was reset by `Structure_Destroy`) gets `Script_Load(type)` here, then runs from the type entry next script-tick. So the **death-script `Script_Load` lives in `GameLoop_Structure`, not in `Structure_Destroy`** — `Structure_Destroy` only `Script_Reset`s (World layer), keeping `ScriptInfo` a Simulation concern, exactly like the unit path (`Unit_Remove` resets; `Unit_SetAction` loads).

OpenDUNE quirk (1.07, not enhanced): if one structure's script errors before running its 3 opcodes, `GameLoop_Structure` **aborts the remaining structures** this tick (`if (!g_dune2_enhanced && i != 3) return;`). We reproduce it.

## The death path

`Structure_Damage → 0 HP → Structure_Destroy` (`structure.c:979`, ported in `GameState+Lifecycle`) sets `variables[0]=1`, clears `allocated`/`repairing`, and `Script_Reset`s — but does **not** free the slot (still `used`, still in the find array). Next script-tick, `GameLoop_Structure`'s else-branch `Script_Load`s the type script; with the death flag set, the shared subroutine at `BUILD.EMC` address 0 branches to:

```
FUNCTION 22  Structure_Explode   → Map_MakeExplosion(EXPLOSION_STRUCTURE=14, tile,0,0) per layout tile  (render-only here; damage 0)
FUNCTION 0   General_Delay(30)
FUNCTION 23  Structure_Destroy   → Structure_Remove(s)  + spawn UNIT_SOLDIER per layout tile (spawnChance/RNG)
```

`Script_Structure_Destroy` (`script/structure.c:589`) is what actually calls `Structure_Remove` (frees the slot, clears `hasStructure`, scrubs references) and spawns soldiers — enemy soldiers `ACTION_ATTACK`, player soldiers `ACTION_MOVE` to a random nearby tile. The GUI "X is destroyed" text is an audio/GUI SEAM.

The disassembly was confirmed by decoding `BUILD.EMC`'s shared subroutine (addresses below the lowest type entry @100): address 0 checks `variables[0]` and, when set, runs Explode→Delay(30)→Destroy. Explode/Destroy appear *only* in that shared routine, which the per-type disassembler view doesn't reach.

## Native table (`g_scriptFunctionsStructure`)

Ported in this slice (`StructureScriptFunctions`):

| op | native | notes |
|----|--------|-------|
| 0x00 | `General_Delay` | reused from `GeneralScriptFunctions` |
| 0x01,0x0C,0x10–0x14,0x18 | `NoOperation` | |
| 0x02 | `Structure_Unknown0A81` | scrub the structure↔unit var-4 link |
| 0x04 | `Structure_SetState` | `DETECT` → resolve from `linkedID`/`countDown`; `Structure_SetState` |
| 0x05 | `General_DisplayText` | SEAM (GUI) → noop |
| 0x06 | `Structure_Unknown11B9` | clear a unit's var-4 + `targetMove` |
| 0x0D | `Structure_GetState` | return `s.state` |
| 0x0E | `Structure_VoicePlay` | SEAM (audio) → noop |
| 0x0F | `Structure_RemoveFogAroundTile` | `Structure_RemoveFog` (player-only, `fogUncoverRadius`) |
| 0x08 | `Structure_FindTargetUnit` | nearest… actually the *last* in-range non-allied seen unit (1.07 picks last, not closest — see below) |
| 0x09 | `Structure_RotateTurret` | step the turret sprite one notch toward the target; 0 = aimed, 1 = rotating |
| 0x0A | `Structure_GetDirection` | the 8-orientation (×32) to a tile, or the turret's current facing if the index is invalid |
| 0x0B | `Structure_Fire` | spawn the turret's bullet/missile at `variables[2]` via `Unit_CreateBullet`; returns the fire delay |
| 0x15 | `Structure_RefineSpice` | convert a linked harvester's spice into the owner's credits (hitpoint-scaled); SetState(IDLE) if unlinked |
| 0x16 | `Structure_Explode` | `Map_MakeExplosion(EXPLOSION_STRUCTURE)` per layout tile |
| 0x17 | `Structure_Destroy` | `Structure_Remove` + soldier spawn |

`RefineSpice` (`structure.c:105`) refines `harvesterStep = (hitpoints·256 / maxHitpoints)·3 / 256` spice per call (so a damaged refinery is slower), clamped to the harvester's remaining `amount`; credits = 7/unit (enemy refineries get a ±RNG bonus), `script.delay = 6` throttles it, and an emptied harvester drops `inTransport`. The `g_scenario` allied/enemy harvested-spice tally is a SEAM (scenario score). The refinery script only reaches it while `state == READY` with a linked harvester (set by `Unit_EnterStructure`).

Deferred (clean-halt the script when reached — loud, not invented) to the **factory/refinery deploy** slice: `FindUnitByType` (0x03, summon a carryall) and `Unknown0C5A` unit-unload (0x07) — both need `Structure_FindFreePosition` + `Unit_SetPosition` (and `FindUnitByType` also `Unit_CallUnitByType`), and the harvester→refinery entry needs `Unit_EnterStructure`. A refinery refines its linked harvester's spice into credits, then halts cleanly at the carryall-summon step until that slice lands.

## Turret firing (0x08–0x0B)

The gun/rocket turret scripts (BUILD.EMC types 15/16) loop: `RemoveFogAroundTile → FindTargetUnit(range) → variables[2] = target → (if target) RotateTurret(target) until aimed → Fire(target) → Delay(fireDelay) → loop`. With these four natives a defensive turret acquires, aims, and fires at a seen enemy.

- **`FindTargetUnit`** scans the unit pool for a non-allied unit within `range` (256/tile; ornithopters use `range*3`) that the structure's house can see (`seenByHouses`, except ornithopters). **1.07 faithfulness:** `distanceCurrent` is initialised to 32000 and *never updated* (OpenDUNE notes the original swapped the assignment, making it a no-op), so the "closest" logic is inert — it returns the **last** matching unit in pool-iteration order, encoded `IT_UNIT` (or 0). We reproduce the 1.07 behaviour, not the enhanced "closest".
- **`RotateTurret`** reads the turret's `groundTileID` (= base sprite + current rotation 0–7; base from `ICM_ICONGROUP_BASE_DEFENSE_TURRET`=23 / `BASE_ROCKET_TURRET`=24 via the `iconMap`), steps it one notch toward `Orientation8(direction to target)`, writes back `groundTileID` + `rotationSpriteDiff`, and returns 0 once aimed. Needs an `iconMap`; the `Map_Update` render redraw is a seam. (A turret's `structureInfo.iconGroup` *is* its ICM base group, so a freshly placed turret starts at rotation 0.)
- **`Fire`** reads `variables[2]`; a rocket turret ≥ 0x300 from its target fires a `UNIT_MISSILE_TURRET` (damage 30, launcher fire delay), else a `UNIT_BULLET` (damage 20, tank fire delay), via the already-ported `Unit_CreateBullet`, stamping the bullet's `originEncoded` with the structure. Returns the speed-adjusted fire delay.

## Testing

Decision-trace / integration: build a `GameState` with a placed structure + the bridged `BUILD.EMC`, drive `Simulation.tick()`, and assert (a) a healthy structure's script loads and idles without error; (b) damaging a structure to 0 HP → `Structure_Destroy` (flag set, slot still present) → subsequent ticks run the death script → `Structure_Remove` frees the slot, drops it from the find array, and clears `hasStructure` on its tiles. Natives with World deps (SetState/GetState/RemoveFog/Explode/Destroy) cross-checked against the World primitives they call.
