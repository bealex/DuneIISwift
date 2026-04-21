# Bullets live in the UnitPool — no separate projectile storage

**Category:** `simulation`

## The fact

It's tempting to design a separate `ProjectilePool` for bullets / missiles / sonic blasts. OpenDUNE doesn't — every fired projectile is a `UNIT_BULLET` / `UNIT_SONIC_BLAST` / `UNIT_MISSILE_*` that occupies one of the same 102 slots the tanks and infantry live in. What keeps them from colliding is the per-type index range baked into every `UnitInfo` row: `indexStart..indexEnd`. `Unit_Allocate(index=UNIT_INDEX_INVALID, type, …)` walks that range looking for the first unused slot; if the range is full, the allocation fails.

The layout in vanilla 1.07:

| Type                                | ID    | Range     | Cap |
|-------------------------------------|-------|-----------|-----|
| CARRYALL / ORNITHOPTER              | 0, 1  | 0..10     | 11  |
| FRIGATE                             | 26    | 11..11    | 1   |
| MISSILE_* / BULLET / SONIC_BLAST    | 18..24 | 12..15   | 4   |
| SANDWORM                            | 25    | 16..17    | 2   |
| (reserved / unused)                 | —     | 18..19    | —   |
| SABOTEUR                            | 6     | 20..21    | 2   |
| INFANTRY / TROOPERS / vehicles      | 2..5, 7..17 | 22..101 | 80  |

## Why it matters

- **Four-bullet cap is a gameplay constraint.** The 12..15 range means at most 4 projectiles exist on the map simultaneously. This is why the original Dune II has a noticeable "bullet queue" during large engagements — further shots wait until the earlier ones resolve. Silently bumping the cap (by moving bullets into their own pool) changes combat pacing.
- **Sandworm count is hard-capped at 2.** Same reason — 16..17 only has 2 slots.
- **`Unit_Allocate`'s "house unitCount" gate doesn't apply to bullets.** The winger / slither early-out skips it. Important: our allocator doesn't yet have `h->unitCount` checking either (deferred), so ground units will "leak" past their cap until P4 Phase 5.

## How to apply

- `UnitPool.allocateForType(type:houseID:)` is the only entry point that respects the type range. `allocate(at:)` bypasses it — don't use it for bullets.
- When adding new unit types in the future (mods, if we ever go there), copy the `indexStart` / `indexEnd` values verbatim from `src/table/unitinfo.c` — they're not derivable.
- Tests that exercise bullets should check the pool slot is inside 12..15 (see `FireTests.createBullet BULLET: allocates in 12..15 with correct fields`).

## Related

- `Documentation/Algorithms/Fire.md` §1 — the full table + rationale.
- `Code/Core/Sources/DuneIICore/Simulation/UnitInfo.swift` — `indexStart` / `indexEnd` per type.
- `Code/Core/Sources/DuneIICore/Simulation/UnitPool.swift` — `allocateForType`.
- `src/pool/unit.c:107` — OpenDUNE's `Unit_Allocate`.
- `src/table/unitinfo.c` — the per-type range values.
