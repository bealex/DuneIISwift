# Tick scheduler — per-tick EMC dispatch

`Simulation.Scheduler` is the outer loop for the scripted side of the simulation. Once per game tick it walks the unit and structure pools, sets `Host.currentObject` to each entity in turn, decrements its `delay` counter or dispatches a bounded number of `VM.step(_:)` opcodes, and moves on.

It is the mirror of OpenDUNE's per-category `*_Tick` functions (`src/unit.c:Unit_Tick`, `src/structure.c:Structure_Tick`) restricted to the script-dispatch portion. The non-script work (rotation, blinking, construction accounting, AI decisions) lives in separate ticks we'll port later.

References:

- OpenDUNE `src/unit.c:Unit_Tick` — the `tickScript` block at lines 289–306.
- OpenDUNE `src/structure.c:Structure_Tick` — the `tickScript` block at lines 325–344.
- `Scripting.VM`, `Scripting.Engine`, `Scripting.Host` — see `EmcVM.md` and `EmcHostFunctions.md`.

## 1. Contract

```swift
public struct Simulation.Scheduler {
    public let host: Scripting.Host
    public let unitVM: Scripting.VM
    public let structureVM: Scripting.VM

    /// Per-slot engines. Parallel to pool slot indices; the slot at
    /// index `n` owns `unitEngines[n]` / `structureEngines[n]`.
    public var unitEngines: [Scripting.Engine]        // length: UnitPool.capacity
    public var structureEngines: [Scripting.Engine]   // length: StructurePool.capacityHard

    public static let unitOpcodesPerTick = 7      // SCRIPT_UNIT_OPCODES_PER_TICK + 2 == 5 + 2
    public static let structureOpcodesPerTick = 3

    public init(host: Scripting.Host,
                unitVM: Scripting.VM,
                structureVM: Scripting.VM)

    /// Runs one full "script tick": walk units (in findArray order),
    /// then walk structures (skipping slab / wall types). Per entity:
    /// decrement engine.delay if non-zero, else step up to N opcodes.
    public mutating func tick()
}
```

`Host` carries the pools. `unitVM` / `structureVM` carry the EMC programs (`UNIT.EMC`, `BUILD.EMC`) and the per-category 64-slot function tables. Engines are per-pool-slot value types owned by the scheduler.

## 2. Per-entity dispatch

For each allocated entity (one iteration of the pool walk), the scheduler does exactly this:

```swift
if engine.delay != 0 {
    engine.delay -= 1
    return
}
var remaining = categoryOpcodesPerTick
while remaining > 0 && engine.delay == 0 {
    if vm.step(&engine) == .halted { break }
    remaining -= 1
}
```

The `delay == 0` check inside the loop matters: a host function that writes `engine.delay` (e.g. `Script_General_Delay`) immediately exits the step loop for the rest of the tick, even if `remaining > 0`. This preserves OpenDUNE's "one outer tick per requested script delay" behaviour.

Opcode budgets:

| Category   | Budget per tick | Rationale (OpenDUNE)                                      |
|------------|-----------------|-----------------------------------------------------------|
| Unit       | 7               | `SCRIPT_UNIT_OPCODES_PER_TICK (= 5) + 2`. Off-viewport units get `3` in OpenDUNE — we do not implement that optimisation yet; it's a pure perf gate. |
| Structure  | 3               | Hardcoded constant in `Structure_Tick`.                   |

## 3. Walk order & skipping rules

Units are visited in `findArray` order (insertion order). OpenDUNE's `Unit_Find` yields the same order; our `UnitPool.next(_:)` with a filter-less `PoolQuery` does too.

Structures are visited in `findArray` order. OpenDUNE's `Structure_Tick` explicitly `continue`s on the three building types that are placed-terrain only — `STRUCTURE_SLAB_1x1`, `STRUCTURE_SLAB_2x2`, `STRUCTURE_WALL`. We port that skip set by their numeric type IDs; the constants are embedded in `Scheduler.skippedStructureTypes`.

The reserved aggregate slots (indices 79, 80, 81) never have live scripts and are filtered automatically by the `next(_:)` walker when their `type` matches the skip set.

## 4. `currentObject` wiring

Before every dispatch (both the decrement-only branch and the step loop), the scheduler sets `host.currentObject` to the appropriate `.unit(poolIndex:)` or `.structure(poolIndex:)` case. After the entire tick finishes, `host.currentObject` is set to `nil`, so host functions called from outside the scheduler (e.g. UI queries) see "no current object".

## 5. What the scheduler does *not* do (yet)

- **Non-script tick work.** Movement, rotation, construction accounting, repair ticks, AI decision ticks — all live in OpenDUNE's other `*_Tick` blocks and will land incrementally as we port the simulation layer. This slice covers the `tickScript` branch only.
- **Off-viewport opcode reduction.** OpenDUNE reduces the unit budget from 7 to 3 for off-viewport units. We hardcode 7 for now; adding viewport awareness is a rendering-layer concern.
- **Stable engine storage across saves.** The `unitEngines` / `structureEngines` arrays are built from the scheduler's initializer. A future `Scheduler(loading: WorldSnapshot)` convenience will pull the engines from each pool slot's save-derived state; currently the caller constructs them.
- **Script load / reset on fresh slots.** When a new unit is allocated mid-game, its engine needs `VM.load(engine:typeID:)` called. The caller does that; the scheduler doesn't know which slots are "newly allocated since last tick".
- **Team scripts.** `g_scriptCurrentTeam` / `Team_Tick` is not wired. Teams land with the AI behaviour slice.

## 6. Test coverage

- `SimulationSchedulerTests.swift:delayCountdownThenDispatch` — unit with `engine.delay = 3` counts down over three ticks (3 → 2 → 1 → 0) without stepping; fourth tick dispatches opcodes.
- Multi-entity walk order: two units allocated in a specific order are ticked in `findArray` order.
- `host.currentObject` is set per-entity during dispatch and cleared after the tick.
- Opcode budget honoured: a program that would run forever halts after `unitOpcodesPerTick` opcodes, and the engine's `pc` advances exactly that many times.
- Host-function `delay` write inside the step loop exits early even with remaining budget.
- Structure skip set: slabs / walls are not dispatched even when their pool slot is used.
