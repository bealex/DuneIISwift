# OpenDUNE caps off-viewport unit scripts at 3 opcodes per tick

- **Discovered**: 2026-04-23 · `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift:tickUnits`, `Repositories/OpenDUNE/src/unit.c:292..294`
- **Category**: simulation
- **Applies to**: any port that runs `UNIT.EMC` scripts under the parity harness — and any gameplay path that claims "OpenDUNE parity"

## The fact

OpenDUNE's `GameLoop_Unit` caps unit scripts by position:

```c
int opcodesLeft = SCRIPT_UNIT_OPCODES_PER_TICK + 2;  /* = 52 */
if (!ui->o.flags.scriptNoSlowdown
 && !Map_IsPositionInViewport(u->o.position, NULL, NULL)) {
    opcodesLeft = 3;
}
```

Two conditions both must be false to trigger the cap:

1. **`scriptNoSlowdown`** is an `ObjectInfo` flag set on 11 of 27 unit types: CARRYALL, ORNITHOPTER, LAUNCHER, HARVESTER, MCV, bullets (types 18..24), SANDWORM, FRIGATE. Ground combat + infantry all have `scriptNoSlowdown = false`.

2. **`Map_IsPositionInViewport`** (`src/map.c:363`) compares the unit's `position` against the 12-bit packed `g_viewportPosition`. Visible rect: `x ∈ [-16, 256], y ∈ [-16, 176]` in 1/16-tile units, roughly 16×11 tiles with margins.

When both are false, the unit's script runs **3 opcodes per tick**. When either is true, it runs **52**. That's a 17× difference in script throughput for the same sim tick.

The viewport position is persisted in the save's `INFO` chunk as `g_minimapPosition`; on load OpenDUNE assigns `g_viewportPosition = g_minimapPosition` (`saveload/info.c:167`). So for parity testing, the save *itself* determines which units get the cap.

## Why it matters

Until 2026-04-23 our Swift `Scheduler.tickUnits` ran `unitOpcodeBudget` opcodes for every unit. For parity mode we'd bumped that to 52 so carryalls and harvesters could match OpenDUNE's rhythm. But SAVE007 has 14 non-slowdown units (trikes, infantry, tanks) mostly scattered off-camera. Our sim ran 52 opcodes on each of those per tick; OpenDUNE ran 3. Compounded across ~12 ticks of script, our units' state drifted violently from the golden.

Tracking this down required opcode-level script tracing on *both* engines — a per-opcode log, side-by-side diff, and the observation that "Swift kept running past the point where OpenDUNE returned." The cap was invisible from state-level diffing; it only showed up in opcode counts.

The tooling that caught it is now permanent:

- OpenDUNE: `--parity-script-trace=<path>` + `--parity-script-unit=<idx>` CLI flags in the parity patch. Hooks into `Script_Run` and logs one line per opcode for the selected unit.
- Swift: `Scripting.VM.trace: TraceHook?` closure called before each `execute`. Assign from tests / harnesses to capture traces without invasive logging.

Ported to our Swift sim:

- `Simulation.UnitInfo.scriptNoSlowdown(type:) -> Bool` — switch over type IDs.
- `Simulation.Scheduler.isInViewport(pos32X:pos32Y:) -> Bool` — port of `Map_IsPositionInViewport`.
- `Simulation.Scheduler.viewportPackedPosition: UInt16` — runtime state, loaded from save / set by harness.
- `Simulation.Scheduler.offViewportSlowdownEnabled: Bool` — toggle (default false for gameplay, true for parity).

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift:tickUnits` — per-unit budget gate.
- `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift:isInViewport` — viewport predicate.
- `Code/Core/Sources/DuneIICore/Simulation/UnitInfo.swift:scriptNoSlowdown(type:)` — type → flag lookup.
- `Code/Core/Sources/DuneIICore/Simulation/ParityHarness.swift:runAgainst` — seeds the viewport + flips the toggle.
- `Code/Core/Sources/DuneIICore/Scripting/Scripting.swift:VM.trace` — opcode-level trace hook.

## Where it lives in the reference

- `src/unit.c:292..294` — the cap itself.
- `src/map.c:363` — `Map_IsPositionInViewport`.
- `src/saveload/info.c:167` — `g_viewportPosition = g_minimapPosition` on load.
- `src/table/unitinfo.c` — `scriptNoSlowdown` column, 27 rows.
