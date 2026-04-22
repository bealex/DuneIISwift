# UNIT.EMC entry points are indexed by unit TYPE, not action

- **Discovered**: 2026-04-21 · `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift:255..268`
- **Category**: scripting
- **Applies to**: anything that loads a unit script engine — scheduler, future save-restore path, any test that reloads a unit VM

## The fact

`UNIT.EMC`'s ORDR chunk contains **27 entry points — one per unit type** (carryall = 0, ornithopter = 1, …, trike = 13, …, frigate = 26). Each entry has a type-specific prologue (e.g. `stackForward 3` for ornithopter) followed by a **shared top-level dispatch that branches on `variables[0]`** (the current action).

So the correct load is `pc = entryPoints[slot.type]` + `variables[0] = slot.actionID`. This is exactly what OpenDUNE does:

```c
// src/unit.c:520..521
u->o.script.variables[0] = action;
Script_Load(&u->o.script, u->o.type);
```

## Why it matters

Loading with `typeID = actionID` looks like it works because:

1. `entryPoints[actionID]` lands on *some* valid address (each index has an entry).
2. The shared dispatch on `variables[0]` still routes to the right path *if* we also wrote `variables[0] = actionID`.

But the PC lands at **another unit type's prologue**. A trike with `actionID = ACTION_MOVE (1)` starts executing the **ornithopter** prologue: `stackForward 3`, then ornithopter's pre-dispatch SetOrientation / Delay / function 60. Ground units end up with ornithopter-style "fly straight and set body orientation every frame" behavior tacked onto their action dispatch — manifesting as:

- **Wrong-direction motion** (ornithopter prologue tweaks orientation/speed).
- **Visible "blinking"** — the prologue of the wrong type fires orientation writes every few opcodes, toggling the sprite-flip bit across octant boundaries.
- **Silent misbehaviour** — tests that just check "any state changed" pass because orientation *is* changing (wrongly).

The bug existed pre-`orderMove` for scenario-spawned units (action = GUARD = 3 → entryPoints[3] = troopers entry), but GUARD's minimal activity made the misbehavior invisible. The player-issued `orderMove` (actionID = MOVE = 1 → ornithopter entry) was the first time this bug became visible in normal play.

## Where it lives in our code

- Scheduler load: `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift:255..268` — uses `slot.type` as the VM typeID + overrides `variables[0]` with `actionID`.
- Regression test: `Code/Core/Tests/DuneIICoreTests/SimulationSchedulerTests.swift` — `schedulerLoadsEntryPointByType`.

## Where it lives in the reference

- `Repositories/OpenDUNE/src/unit.c:497..522` (`Unit_SetAction`).
- `Repositories/OpenDUNE/src/script/script.c:277..289` (`Script_Load` — sets PC only, never touches variables).

## Gotcha for future work

`Scripting.VM.load` still seeds `variables[0] = typeID` as a safety net (OpenDUNE's `Script_Load` doesn't). Callers that load a unit engine by `slot.type` **must overwrite `variables[0]` to `actionID` after** — otherwise the dispatch will read `variables[0] == type` and branch into the ACTION_ATTACK path (0) or whatever type matches.

Structures don't have this problem — `entryPoints[structureType]` IS what OpenDUNE loads, and structures dispatch off their own internal state, not `variables[0]`.
