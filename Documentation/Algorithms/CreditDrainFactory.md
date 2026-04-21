# Factory credit drain + refund (slice 6c)

Status: Drafted 2026-04-21 (P5 slice 6c — extends slice 6b's drain/refund to factories).

Slice 6b wired credit drain + cancel refund for construction yards only. Slice 6c extends it symmetrically to the 5 factory yards (LV / HV / HIGH_TECH / WOR / BARRACKS) by porting `UnitInfo.buildCredits` (27 rows) and dispatching the cost lookup by yard kind.

No algorithm changes — same `costPerTick = buildCredits / buildTime`, same pause-on-no-credits, same refund formula. Just an additional lookup path.

References:

- `src/table/unitinfo.c` — `ObjectInfo.buildCredits` field.
- `Documentation/Algorithms/CreditDrainAndRefund.md` — parent slice.

## 1. `UnitInfo.buildCredits`

27 values from `src/table/unitinfo.c`. Summary:

| type | name            | buildCredits |
|------|-----------------|--------------|
| 0    | Carryall        | 800          |
| 1    | Thopter         | 600          |
| 2    | Infantry        | 100          |
| 3    | Troopers        | 200          |
| 4    | Soldier         | 60           |
| 5    | Trooper         | 100          |
| 6    | Saboteur        | 120          |
| 7    | Launcher        | 450          |
| 8    | Deviator        | 750          |
| 9    | Tank            | 300          |
| 10   | Siege Tank      | 600          |
| 11   | Devastator      | 800          |
| 12   | Sonic Tank      | 600          |
| 13   | Trike           | 150          |
| 14   | Raider Trike    | 150          |
| 15   | Quad            | 200          |
| 16   | Harvester       | 300          |
| 17   | MCV             | 900          |
| 18+  | projectiles/misc| 0            |

Added as a new stored property on `UnitInfo` with a default of `0` on the memberwise init. 17 non-zero rows updated (18..26 are projectiles / sandworm / frigate — 0 already the default).

## 2. Dispatch in `tickConstruction` + `cancelConstruction`

Both paths already handle CY via `StructureInfo.lookup(objectType)`. Slice 6c adds the mirror factory path:

```swift
// `info` is the produced object's info — StructureInfo for CY,
// UnitInfo for factory. Extract costPerTick + buildTime for the math.
let buildCredits: UInt16
let buildTime: UInt16
if slot.type == 8 /* CYARD */,
   let sInfo = StructureInfo.lookup(UInt8(truncatingIfNeeded: slot.objectType))
{
    buildCredits = sInfo.buildCredits
    buildTime = sInfo.buildTime
} else if let uInfo = UnitInfo.lookup(UInt8(truncatingIfNeeded: slot.objectType)) {
    buildCredits = uInfo.buildCredits
    buildTime = uInfo.buildTime
} else {
    // no-op drain (matches slice 6b behaviour for unset objectType)
    ...
}
```

The rest of the math is identical. Factored into a private helper on `Simulation.Structures` so both `tickConstruction` and `cancelConstruction` share it.

## 3. What slice 6c does NOT cover

- **`buildCostRemainder` fractional accumulator** — still integer cost-per-tick. Off-by-a-few-credits error at completion. Later slice if parity becomes a measurable issue.
- **HUD display** — slice 6d.
- **Starting-credits defaults for scenarios that don't specify them** — every spot where the player has 0 credits in mission 1 would block all construction. Slice 6d can seed reasonable defaults alongside the HUD.
- **AI credit drain** — AI yards also drain now (they go through the same code path). This is fine for OpenDUNE parity; AI economies are self-regulating.

## 4. Testing

Extend `StructureConstructionTests` (drain) + `FactoryBuildableTests` (refund):

### Factory drain

- BUSY BARRACKS building SOLDIER (`60 / 32 = 1` cost/tick): 1 tick → credits -= 1, countDown -= 256.
- BUSY LV factory building TRIKE (`150 / 40 = 3`): 1 tick → credits -= 3.
- Factory with 0 credits → paused (same as CY).

### Factory refund

- Cancel fresh BUSY BARRACKS + SOLDIER → 0 refund.
- Cancel half-built BARRACKS + SOLDIER (countDown = 4096 = 16 << 8) → refund = 16 × 60 / 32 = 30.

### `UnitInfo.buildCredits`

- Pinned spot checks (Carryall = 800, MCV = 900, Soldier = 60, Sandworm = 0).

## 5. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/UnitInfo.swift` — new field + 17 non-zero rows.
- `Code/Core/Sources/DuneIICore/Simulation/Structures.swift` — dispatch in drain + refund.
- `Code/Core/Tests/DuneIICoreTests/FactoryBuildableTests.swift` — extended.
- `Code/Core/Tests/DuneIICoreTests/StructureConstructionTests.swift` — extended.
