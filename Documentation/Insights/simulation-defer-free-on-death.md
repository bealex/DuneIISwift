# Unit hp=0 → ACTION_DIE, not immediate free

- **Discovered**: 2026-04-24 · `Code/Core/Sources/DuneIICore/Simulation/Explosions.swift` + SAVE007 tick-199 parity drift
- **Category**: simulation
- **Applies to**: any damage-dealing path that reduces a unit's `hitpoints` to zero (bullet impact, explosion radius, structure attack, deviator effect).

## The fact

OpenDUNE's `Unit_Damage` at `src/unit.c:1554..1568` does NOT free a unit when hp reaches 0. It:

1. Calls `Unit_RemovePlayer(unit)` (drops the unit from the player's selection / info panel).
2. Handles type-specific on-death side effects (harvester spice spill, saboteur audio, "unit lost" voice message).
3. Calls `Unit_SetAction(unit, ACTION_DIE)`.
4. Returns `true`.

The unit **stays in the pool** with `actionID = ACTION_DIE` (10). On the next script-cadence tick the unit's EMC script dispatches into the DIE action entry, which eventually calls `Script_Unit_Die` (slot 0x0F) — *that's* what frees the slot via `Unit_Free`. Between "hp hit 0" and "slot freed" the unit is visible as a corpse (DIE action plays a short sprite-offset animation).

Swift's first-pass `Simulation.Explosions.applyUnitDamage` freed the slot immediately on hp=0 and separately spawned a corpse sprite via the explosion pool. Visually indistinguishable in gameplay, but **sim-state divergent** — the unit-pool dump at any kill tick has `isUsed=false` in Swift vs `isUsed=true action=10` in OpenDUNE.

## Why it matters

- **Pool-slot parity**: any engine that reads `isUsed` / `actionID` (bullet targeting, FindBestTarget, info panels, minimap dots) sees a different answer on the kill tick. For deterministic parity runs this is a real divergence, not a cosmetic one.
- **Side-effects owned by the DIE script**: OpenDUNE's `Script_Unit_Die` also updates house kill counts, plays the per-type death sound, triggers saboteur explosions, etc. Freeing early robs the EMC of the chance to run any of that.
- **Corpse-sprite source**: OpenDUNE renders the corpse by displaying the dying unit's sprite cycle during ACTION_DIE, not via a separate pool. Swift uses a dedicated explosion-pool entry for corpse visuals and that works for gameplay, but layering both would double the visual.

## How Swift handles it

A `Host.deferFreeOnDeath: Bool = false` flag gates the parity behavior. When true (parity harness), `applyUnitDamage` writes `actionID = ActionID.die` and leaves the slot alive; the existing `makeDieUnit` wiring (slot 0x0F in the unit function table) frees it on the next script dispatch, matching OpenDUNE's pipeline. When false (gameplay default), the old immediate-free + explosion-pool-corpse path is preserved so the rendering layer doesn't need changes.

Longer-term, gameplay should migrate to the OpenDUNE-style pipeline too — see `Script_Unit_Die` for the full side-effect list that still needs porting (kill counts, per-type death audio, saboteur explosion).

## Related

- [simulation-action-id-drives-script-reload](simulation-action-id-drives-script-reload.md) — once `actionID` flips to `.die`, the scheduler's action-delta check reloads the EMC entry point to the DIE section.
- [simulation-per-tick-rng-order-matters](simulation-per-tick-rng-order-matters.md) — the parity harness that surfaced this drift depends on every kill path matching OpenDUNE's cadence.
