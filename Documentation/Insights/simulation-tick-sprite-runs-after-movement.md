# `tickUnknown5` (sprite animation) runs AFTER `Unit_MovementTick` in OpenDUNE's per-unit loop

- **Discovered**: 2026-04-24 · `Repositories/OpenDUNE/src/unit.c:199..287`
- **Category**: simulation
- **Applies to**: `Simulation.Scheduler.tick()` — any call to `tickSpriteOffsets()` must happen after `tickMovement()` + `tickRotation()`.

## The fact

OpenDUNE's `GameLoop_Unit` per-unit inner loop runs in this order (`src/unit.c:199..287`):

1. `tickMovement` → `Unit_MovementTick` — advances position, and **clears `speed` on arrival** (`src/unit.c:1419`'s distance-to-destination overshoot check).
2. `tickRotation` → `Unit_Rotate`.
3. `tickBlinking`.
4. `tickDeviation`.
5. `tickUnknown5` — the sprite-animation pass at `src/unit.c:239..287` whose FOOT branch reads `ui->movementType == MOVEMENT_FOOT && u->speed != 0`.
6. `tickScript`.

The sprite branch's `speed != 0` gate is **load-bearing**: when a foot unit arrives this tick, step 1 zeroes speed and step 5 correctly refuses to bump `spriteOffset`. Any scheduler that runs the sprite pass before movement will see the pre-arrival `speed = 1` and animate one extra frame on every arrival tick.

## Why it matters

Swift's `Scheduler.tick()` originally ran `tickSpriteOffsets()` near the top (right after `tickFireCooldowns`) — before `tickMovement()`. The SAVE007 u37 tick-76 parity drift (`spriteOffset = 8` vs OpenDUNE's `7`) was exactly this: u37 finished its final step on tick 76, Swift animated once more before movement cleared speed, OpenDUNE didn't.

The fix is purely a re-order; the sprite pass doesn't need any logic change. See commit [SAVE007 parity tick 41 → 151 via 6 stacked fixes] and the `tickSpriteOffsets` call site in `Scheduler.swift`.

## Subtle: `timer` decrement also runs in the sprite pass

The sprite pass at `src/unit.c:284..286` decrements `u->timer` in the `else` branch of the `timer == 0` check. That's the same timer that gates the next animation step, so the order doesn't affect `timer` parity across ticks as long as the pass consistently runs once per cadence fire. But if the pass ever accidentally runs twice (or half-runs), `timer` will drift silently — the parity harness catches this via the `timer` field compare, which is how the original timer-gate port was debugged (see `Simulation.tickUnknown5-animationspeed-divide-5.md` when written).
