# `Unit_UntargetMe` sweeps every other unit before free

- **Discovered**: 2026-04-24 · `Code/Core/Sources/DuneIICore/Simulation/Units.swift` + SAVE007 tick-201 parity drift
- **Category**: simulation
- **Applies to**: any code path that frees a unit slot (`Script_Unit_Die`, explicit unit removal from the pool).

## The fact

When OpenDUNE frees a unit via `Unit_Remove` (`src/unit.c:897`), it does NOT just mark the slot `used=false`. It first calls `Unit_UntargetMe` (`src/unit.c:1611`), which walks every unit in the pool and clears any `targetMove` / `targetAttack` / `scriptVariables[4]` field that still encodes the freed slot. It also sweeps turret-kind structures (`STRUCTURE_TURRET` / `STRUCTURE_ROCKET_TURRET`) and every team, clearing their matching target references.

The encoded-index shape is `{kind: IT_UNIT, index: poolIndex}` (16-bit, `0x4000 | index`). Without the untarget sweep, after a free:

- Another attacker's `targetAttack` still reads `0x4024` (encoded u36), but u36's slot is now unused.
- `Tools_Index_GetUnit(0x4024)` returns NULL, and downstream code *usually* handles that gracefully.
- But the saved / dumped pool state still shows the stale 0x4024, so byte-for-byte parity dumps diverge at the exact tick the slot was freed.
- More importantly, the stale reference survives across tick boundaries — attackers keep "targeting" a non-existent unit until some later code path happens to overwrite `targetAttack` / `targetMove`.

## Why it matters

- **Parity dumps**: any harness that compares unit-pool bytes will diverge the instant a kill event happens, even if all other sim state is identical.
- **Correctness**: some scheduler passes branch on `targetMove != 0` as "unit is trying to go somewhere." Without the sweep, attackers keep chasing a ghost.

## How Swift handles it

`Simulation.Units.untargetUnit(poolIndex:host:)` mirrors `Unit_UntargetMe`'s unit-pool sweep (structure + team sweeps are TODO until those script-variable fields land). `Scripting.Functions.makeDieUnit` calls it right before `host.units.free(...)`.

## Related

- [simulation-defer-free-on-death](simulation-defer-free-on-death.md) — hp=0 transitions to ACTION_DIE without freeing. The free happens later via the DIE script dispatch, at which point `Unit_UntargetMe` fires. Both insights live on the same kill-path sequence.
