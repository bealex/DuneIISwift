# Writing `slot.actionID` is enough to re-enter the script

- **Discovered**: 2026-04-21 · `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift:250..260`
- **Category**: simulation
- **Applies to**: any pure-sim helper that wants to "kick" a unit into a new action (player orders, AI retargeting, scripted events)

## The fact

The scheduler tracks a per-slot `loadedUnitAction: [Int?]` and, at the top of `tickUnits`, compares `loadedUnitAction[idx]` against `Int(slot.actionID)`. When they differ, it calls `unitVM.load(engine: &unitEngines[idx], typeID: action)` which resets the script engine's PC to the matching entry point for that action.

So: to force a unit to re-run its ACTION_MOVE script, all you have to do is write `slot.actionID = Simulation.ActionID.move`. No `Script_Reset`. No `Script_Load`. No explicit engine poke.

## Why it matters

OpenDUNE's `Unit_SetAction` (`src/unit.c:497`) does the reset + load explicitly — if you port it literally, you also have to port those. Our scheduler moves that responsibility to the per-tick pass, so pure-sim helpers like `Simulation.Units.orderMove` stay tiny: four lines of slot-field writes, no coupling to the VM.

The flip side: a caller that wants to *prevent* a script reload (e.g. "retarget but don't restart the attack loop") has to leave `actionID` alone. The only knob is the field itself. There's no "silent retarget."

## Where it lives in our code

- The reload detector: `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift:250..260`.
- Sample consumer: `Code/Core/Sources/DuneIICore/Simulation/Units.swift` — `orderMove` writes `actionID = move` without any VM coupling.

## Where it lives in the reference

OpenDUNE splits the work differently. `Unit_SetAction` (`src/unit.c:497..522`) does:

```c
u->actionID = action;
u->nextActionID = ACTION_INVALID;
u->currentDestination.x = 0;
u->currentDestination.y = 0;
u->o.script.delay = 0;
Script_Reset(&u->o.script, g_scriptUnit);
u->o.script.variables[0] = action;
Script_Load(&u->o.script, u->o.type);
```

That's four fields + two VM calls. Our scheduler absorbs the two VM calls; we just do the four fields.
