# `Unit_Free` mid-iteration skips the next unit's whole tick body

- **Discovered**: 2026-04-24 · SAVE007 tick-691 parity drift (`u26.fireDelay=48 vs 47`)
- **Category**: simulation
- **Applies to**: any per-tick logic placed inside the `Unit_Find` loop body — `Unit_MovementTick`, `u->fireDelay--`, `Unit_Rotate`, sprite tick, script dispatch, blink, deviation, smoking.

## The fact

OpenDUNE's `Unit_Free` (`src/pool/unit.c:161`) doesn't just clear the slot — it `memmove`s the entire `g_unitFindArray` tail one position to the LEFT to close the gap (`src/pool/unit.c:184`). Then the outer `Unit_Find` loop in `GameLoop_Unit` does `find->index++` and reads `g_unitFindArray[find->index]`.

Net effect: when a unit dies mid-iteration (its DIE script calls `Unit_Remove` → `Unit_Free`), **the unit that was at `findArray[cursor + 1]` shifts to `findArray[cursor]`, the cursor advances to `cursor + 1`, and that next unit's whole tick body is silently skipped**. No movement tick. No `fireDelay` decrement. No rotation. No script dispatch.

The skipped unit catches up next tick. So the visible effect is a single-tick stutter for whichever unit happens to follow the dying unit in find-array order.

## Why it matters

Anything that needs byte-exact OpenDUNE parity has to reproduce this skip. SAVE007 tick 691 surfaced it: u25 (TROOPER, hp=0 since tick 688) finally completes its DIE script and frees the slot at tick 691. u26 (Atreides TANK at findArray position cursor+1) shifts into u25's cursor. The loop advances past u26. OpenDUNE's u26.fireDelay stays at 48 that tick; u26 catches up at tick 694 instead of 691.

Swift had a separate **batched** `tickFireCooldowns()` pass that ran outside the per-unit loop. After u25's free, the findArray was already shrunk; the batched pass visited every remaining entry, including u26, and decremented fireDelay → 47. Tick-691 parity broke.

This applies to ANY tick-body logic, not just fireDelay. If you split a per-unit pass into a batched pass (or vice versa), check whether mid-loop frees can occur and whether they should propagate the skip.

## How to fix in Swift

Match OpenDUNE's structural choice: keep all per-unit tick logic INSIDE the interleaved `for cursor in findArray` loop, not in adjacent batched passes.

```swift
while cursor < host.units.findArray.count {
    let idx = host.units.findArray[cursor]
    if unitMovementEnabledThisTick {
        tickMovement(fromFindArrayIndex: cursor, singleUnit: true)
        // INLINE the decrement here — if the script later in this
        // iteration frees idx, the next loop pass advances past
        // the shifted unit and silently skips it.
        if idx < host.units.slots.count {
            var slot = host.units.slots[idx]
            if slot.isUsed, slot.fireDelay != 0 {
                slot.fireDelay &-= 1
                host.units[idx] = slot
            }
        }
    }
    // ... rotation, sprite, script ...
    cursor += 1
}
```

Don't add a "fixup" pass that walks survivors after the loop — that re-introduces the bug.

## Related

- [simulation-defer-free-on-death](simulation-defer-free-on-death.md) — `deferFreeOnDeath` keeps a unit alive across multiple ticks running ACTION_DIE so the skip happens on the tick the slot is actually freed, not the tick hp hits 0.
- [simulation-per-tick-rng-order-matters](simulation-per-tick-rng-order-matters.md) — adjacent insight on why batched-vs-per-unit dispatch matters for RNG byte attribution.
