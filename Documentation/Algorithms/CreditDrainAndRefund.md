# Credit drain + cancel refund (slice 6b — CY path)

Status: Drafted 2026-04-21 (P5 slice 6b — CY credit drain + cancel refund; factory drain deferred to 6c).

Slice 6a plumbed `credits / creditsStorage / creditsQuota` into `Simulation.HouseSlot`. Slice 6b wires the drain: every tick, each BUSY construction yard deducts a slice of the produced structure's `buildCredits` from the owning house. If the house can't pay this tick, the countdown pauses (state stays BUSY; `countDown` doesn't advance). Cancelling refunds credits proportional to how much was already spent.

Factory drain (unit production) stays deferred to **slice 6c** — it requires `UnitInfo.buildCredits` (27 rows) + the same dispatch already present in `startConstruction`. Splitting keeps this slice narrow.

References:

- `src/gui/gameloop.c:GameLoop_Structure` — the per-tick `countDown` + credit drain.
- `src/structure.c:Structure_CancelBuild` — refund formula.

## 1. Drain formula

OpenDUNE divides `buildCredits` across `buildTime` ticks and uses a fractional accumulator (`buildCostRemainder`) to smooth integer-arithmetic rounding. For slice 6b we use a simpler integer cost-per-tick:

```
costPerTick = max(1, info.buildCredits / info.buildTime)
```

For WINDTRAP (buildCredits = 300, buildTime = 48): `costPerTick = 6`. Over 48 ticks that's 288 — close to the nominal 300. Integer rounding error is acceptable for slice 6b; slice 6c / 6d can port the full `buildCostRemainder` accumulator.

Per BUSY yard per tick:

1. Look up the produced object's info (CY only in this slice).
2. If `info == nil` or `buildTime == 0` or `objectType == 0xFFFF` → skip drain, advance countdown normally (matches the "unmarked BUSY" tests that came before slice 6a).
3. If `house.credits >= costPerTick`: deduct, advance countdown by 256 (or flip to READY).
4. Else: don't advance countdown this tick. Yard stays BUSY until credits arrive.

## 2. Cancel refund formula

Port of the `Structure_CancelBuild` refund line:

```c
credits += ((buildTime - (countDown >> 8)) * 256 / buildTime) * buildCredits / 256
```

Simplification: `credits += ticksSpent * buildCredits / buildTime` where `ticksSpent = buildTime - countDown >> 8`. For WINDTRAP half-built (buildTime = 48, countDown = 6144 = 24 << 8): `ticksSpent = 24`, refund = `24 * 300 / 48 = 150`. Matches the "paid 150 credits so far" intuition.

Clamped to `UInt16` on add.

## 3. Signature changes

```swift
public static func tickConstruction(
    pool: inout StructurePool,
    houses: inout HousePool
)

public static func cancelConstruction(
    yardIndex: Int,
    pool: inout StructurePool,
    houses: inout HousePool
) -> Bool
```

Both gain a required `houses: inout HousePool` parameter. Existing callers (Scheduler, `ScenarioScene.cancelConstructionOnYard`) copy and write back `host.houses` alongside the structure pool.

Existing tests that manually set `state = BUSY` without going through `startConstruction` leave `objectType == 0xFFFF` (default), so the drain path is a natural no-op for them — they only need the new `HousePool` argument. The `fullWindtrapBuild` test (which goes through `startConstruction`) seeds Atreides credits upfront so drain doesn't pause the ticking.

## 4. What slice 6b does NOT cover

- **Factory drain** — HV / LV / HIGH_TECH / WOR / BARRACKS don't drain. Needs `UnitInfo.buildCredits` + dispatch. Slice 6c.
- **`buildCostRemainder` accumulator** — we use integer cost-per-tick. Off-by-a-few-credits error at completion. Slice 6c or 6d.
- **Storage cap enforcement on credits** — credits can go above `creditsStorage`. Deferred.
- **HUD** — no "Credits: N" label yet. Slice 6d.
- **Refund rounding exactly matches OpenDUNE** — we use a slightly different formula for readability; the refund total is within 1 credit of OpenDUNE at tick boundaries.

## 5. Testing

Extend `StructureConstructionTests` (drain) + `FactoryBuildableTests` (refund):

### Drain

- BUSY CY building WINDTRAP, house has 1000 credits → after 1 tick credits = 994, countDown = 12032.
- BUSY CY building WINDTRAP, house has 0 credits → countDown unchanged (paused).
- BUSY CY with `objectType = 0xFFFF` (synthetic) → drain skipped, countdown advances.
- Full WINDTRAP build with 1000 starting credits drains to 712 credits (= 1000 - 288) at READY.
- IDLE yard: no drain attempted.

### Refund

- Cancel a fresh (just-started) BUSY WINDTRAP: refund = 0, credits unchanged.
- Cancel a half-built BUSY WINDTRAP (countDown = 6144): refund = 150, credits += 150.
- Cancel a READY WINDTRAP (countDown = 0): refund = 300 (full).
- Cancel with `objectType = 0xFFFF` → no refund math (skip); state still resets.

## 6. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/Structures.swift` — `tickConstruction` + `cancelConstruction` gain `houses:` param; new drain + refund math.
- `Code/Core/Sources/DuneIICore/Simulation/Scheduler.swift` — passes `host.houses` to the tick.
- `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — `cancelConstructionOnYard` copies houses around the call.
- `Code/Core/Tests/DuneIICoreTests/StructureConstructionTests.swift` — tick-path tests updated + drain cases added.
- `Code/Core/Tests/DuneIICoreTests/FactoryBuildableTests.swift` — cancel tests updated + refund cases added.
