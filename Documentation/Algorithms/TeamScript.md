# Team scripts + `GameLoop_Team`

Design of record for the team AI subsystem: bridging `TEAM.EMC` into a `ScriptInfo`, running team EMC scripts each loop (`GameLoop_Team`), and the team script native table. Source of truth: OpenDUNE `src/team.c`, `src/script/team.c`, `src/script/script.c`.

A "team" is OpenDUNE's small-unit-group AI: a `Team` owns a `ScriptEngine` and a handful of member units, and its `TEAM.EMC` script (selected by `TeamActionType`) recruits units, picks targets, and issues orders. Teams are created from the scenario `[TEAMS]` section and during play; the *human* player has no teams — only `isAIActive` houses' teams run.

## Same VM, third table + program

A team runs the *same* EMC interpreter as a unit/structure (`ScriptInterpreter` / one opcode per `Script_Run`). Like the others, only the program + native table differ (`script.c`):

- **The program.** Teams share one `ScriptInfo` bridged from `TEAM.EMC` (`g_scriptTeam`). The per-action entry is `offsets[teamActionType]` (the `ORDR` chunk) — `Script_Load(&t->script, t->action)` (`team.c:91`), where `action` is a `TeamActionType` (0 normal, 1 staging, 2 flee, 3 kamikaze, 4 guard). Identical mechanics to units (indexed by action) and structures (indexed by type).
- **The native table.** Op-14 `FUNCTION n` indexes `g_scriptFunctionsTeam` (the `Script_Team_*` natives). Our `TeamScriptRunner.dispatch` is the team analog of the unit/structure dispatch.

Each team carries its own `ScriptEngine` (`t.script`) — PC, stack, frame pointer, `variables`, `delay`.

## `GameLoop_Team` (`team.c:22`)

Unlike the unit/structure loops (per-activity next-due cursors), the team loop has **one** cursor with a *random* period:

```
if s_tickTeamGameLoop > g_timerGame: return
s_tickTeamGameLoop = g_timerGame + (Tools_Random_256() & 7) + 5      // 5…12 ticks
```

So `GameLoop_Team` fires every 5–12 ticks (one `Random256` draw each fire), and on each fire walks every team (`Team_Find`):

```
h = House_Get_ByIndex(t.houseID)
if !h.flags.isAIActive:        continue          // human / inactive houses' teams don't run
if t.script.delay != 0:        t.script.delay--; continue
if !Script_IsLoaded:           continue
if !Script_Run(t.script):      break             // 1.07 (not enhanced): one script error aborts the rest
```

Note the differences from the structure loop: **one** `Script_Run` per team per fire (not a 3-opcode batch), and the AI-active gate. The 1.07 "abort all remaining teams on a script error" quirk (`if (!g_dune2_enhanced) break;`) is reproduced — and an unported native clean-halts (`Script_Run` → false), so it both stops that team and breaks the loop.

The cursor `teamLoopTick` is mutable sim state → it lives in `GameState` (the team analog of `structureTick`/`houseTick`).

## Native table (`g_scriptFunctionsTeam`, 0x00–0x0E)

| op | native | status |
|----|--------|--------|
| 0x00 | `General_Delay` | **live** (shared) |
| 0x01 | `Team_DisplayText` | no-op (GUI SEAM) |
| 0x02 | `Team_GetMembers` → `members` | **live** |
| 0x03 | `Team_AddClosestUnit` | **live** (recruit nearest eligible unit) |
| 0x04 | `Team_GetAverageDistance` | **live** (centroid + mean distance) |
| 0x05 | `Team_Unknown0543` | **live** (move strayed members back / Guard) |
| 0x06 | `Team_FindBestTarget` | **live** (member's best target → team target) |
| 0x07 | `Team_Unknown0788` | **live** (order members to attack the team target) |
| 0x08 | `Team_Load` | **live** (switch action script) |
| 0x09 | `Team_Load2` | **live** (restore `actionStart` script) |
| 0x0A | `General_DelayRandom` | **live** (shared) |
| 0x0B | `General_DisplayModalMessage` | no-op (GUI SEAM) |
| 0x0C | `Team_GetVariable6` → `minMembers` | **live** |
| 0x0D | `Team_GetTarget` → `target` | **live** |
| 0x0E | `General_NoOperation` | **live** (shared) |

The getters (`GetMembers`/`GetVariable6`/`GetTarget`) read the running team's fields (`g_scriptCurrentTeam` → `state.teams[slot]`); the **recruit + target** natives (`AddClosestUnit`/`GetAverageDistance`/`FindBestTarget`) act on the team's membership + target. All are plain explicit-param functions in `TeamScriptFunctions`. `FindBestTarget` reuses the unit runner's `TargetFinder` (so `TeamScriptRunner` carries the optional `UnitScriptRunner`); the new World primitives it leans on are `Unit_AddToTeam` and `Tile_GetTileInDirectionOf` (a random valid tile toward the target). The **order-issuing** natives `Unknown0543` (move strayed members back to a random tile near the centroid, else Guard) and `Unknown0788` (set members to Attack the team target at a random firing position around it) take the unit-action layer — `UnitActions.setAction` + `UnitScriptFunctions.unitSetDestination`/`unitSetTarget` — explicitly (so they clean-halt only when `TeamScriptRunner` has no `UnitScriptRunner`). `Load`/`Load2` switch the team's action script by `interpreter.load`-ing the **passed-in `engine`** (the live VM copy the runner writes back), not `state.teams[slot].script` — otherwise the runner's post-run write-back clobbers the reload. The full `g_scriptFunctionsTeam` table is now live; **team *creation*** (the scenario `[TEAMS]` section + `Team_Create`/`Team_Add`) is the next slice so real teams exist to run these.

## Testing

Real-data: bridge the committed `TEAM.EMC`, allocate an `isAIActive` team, `Script_Load(action)`, drive `Simulation.tick()` and assert the loop fires on the cursor + runs as far as the ported natives reach. Decision-trace: each getter native against a hand-set `Team`. The loop's AI-active gate, delay decrement, and the random cursor period are unit-tested directly.
