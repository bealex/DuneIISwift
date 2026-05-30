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
| 0x16 | `Structure_Explode` | `Map_MakeExplosion(EXPLOSION_STRUCTURE)` per layout tile |
| 0x17 | `Structure_Destroy` | `Structure_Remove` + soldier spawn |

Deferred (clean-halt the script when reached — loud, not invented) to later slices: `FindUnitByType` (0x03), `Unknown0C5A` unit-unload (0x07), `FindTargetUnit` (0x08), `RotateTurret` (0x09), `GetDirection` (0x0A), `Fire` (0x0B) — the **turret-firing** slice; `RefineSpice` (0x15) — the **refinery/economy** slice. A healthy structure's idle loop (set-state / remove-fog / delay) runs fully; turret and refinery structures halt cleanly at their first unported native until those slices land.

## Testing

Decision-trace / integration: build a `GameState` with a placed structure + the bridged `BUILD.EMC`, drive `Simulation.tick()`, and assert (a) a healthy structure's script loads and idles without error; (b) damaging a structure to 0 HP → `Structure_Destroy` (flag set, slot still present) → subsequent ticks run the death script → `Structure_Remove` frees the slot, drops it from the find array, and clears `hasStructure` on its tiles. Natives with World deps (SetState/GetState/RemoveFog/Explode/Destroy) cross-checked against the World primitives they call.
