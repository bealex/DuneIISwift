# `House_Free` removes from find-array but never clears `flags.used`

- **Discovered**: 2026-04-20 · `Code/Core/Sources/DuneIICore/Simulation/HousePool.swift`
- **Category**: simulation
- **Applies to**: `Simulation.HousePool`, save-file round-tripping for houses, any future logic that "resets" a house slot.

## The fact

OpenDUNE's `House_Free` only mutates the find-array. It does not clear `h->flags.used` or zero the slot:

```c
void House_Free(House *h) {
    int i;
    for (i = 0; i < g_houseFindCount; i++) {
        if (g_houseFindArray[i] == h) break;
    }
    g_houseFindCount--;
    if (i == g_houseFindCount) return;
    memmove(...);
}
```

After `House_Free`, the slot:

- Is **invisible** to `House_Find` (gone from the find-array).
- Still satisfies `h->flags.used == true`.
- Cannot be re-allocated via `House_Allocate(index)` — that function rejects any slot whose `flags.used` is set.

This looks like a missing line. It is observable behaviour: any code that frees a house and later tries to re-allocate the same index silently fails.

## Why it matters

A "tidy" Swift port that clears `isUsed` in `HousePool.free(at:)` diverges from OpenDUNE on save-file round-trips: a save written by OpenDUNE with a freed-but-still-used house slot would round-trip differently after our reset. We mirror the quirk byte-for-byte. Anyone who actually needs to reset a house slot must mutate `slots[i]` directly.

In the original game houses are never freed during play, so the quirk is unreachable from gameplay. It still matters for save-file fidelity and for any modding / debugging path that exercises the full allocator surface.

## Where it lives in our code

- `Code/Core/Sources/DuneIICore/Simulation/HousePool.swift::free(at:)` — only removes from `findArray`, leaves `slots[i].isUsed`.
- Test: `Tests/DuneIICoreTests/PoolTests.swift::houseFreeLeavesUsed` exercises the quirk and asserts re-allocation of the same slot returns `nil`.

## Where it lives in the reference

OpenDUNE `src/pool/house.c::House_Free`. Compare with `src/pool/unit.c::Unit_Free` and `src/pool/structure.c::Structure_Free`, both of which **do** clear `flags` via `memset(&u->o.flags, 0, sizeof(u->o.flags))`. The omission is house-specific.
