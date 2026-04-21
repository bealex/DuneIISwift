# House credits — field plumbing (slice 6a)

Status: Drafted 2026-04-21 (P5 slice 6a — HUD/economy groundwork, pure sim plumbing).

The credit state exists at the edges: `Scenario.HouseLayout.credits` reads from INI scenarios; `Formats.Save.Players.Slot.credits` / `creditsStorage` / `creditsQuota` read from save files. The middle — `Simulation.HouseSlot` — doesn't carry any cash state. Slice 6a wires the pool slot to track the three credit fields and plumbs them through both `WorldSnapshot` init paths.

No drain, no HUD, no cancel refund — those are slices 6b and 6c. Slice 6a is the narrowest "save and scenario round-trip the credit state" gate.

References:

- `src/house.h` — `House.credits`, `House.creditsStorage`, `House.creditsQuota`.
- `src/table/houseinfo.c` — default starting credits per house (not used here; scenarios override).
- `src/pool/house.c:House_Allocate` — plain pool allocation with no credit initialisation.

## 1. Three new fields on `Simulation.HouseSlot`

```swift
public var credits: UInt16
public var creditsStorage: UInt16
public var creditsQuota: UInt16
```

All `UInt16` to match the save record; all default to `0` on init.

- `credits` — spending cash. Drained per tick by BUSY yards (slice 6b); refunded on cancel.
- `creditsStorage` — cap on storable credits. Computed from refineries + silos at runtime. Stored so save round-trips survive; recomputed lazily when the economy subsystem lands.
- `creditsQuota` — scenario win condition (harvester-collected credits target). Pure read; never written by the engine.

## 2. Scenario-path plumbing

`Scenario.HouseLayout` already exposes `credits: Int` + `quota: Int` from the INI loader. `WorldSnapshot.init(scenario:resolver:)` gains a secondary pass after house allocation to copy those fields:

```swift
for (house, layout) in scenario.houses {
    let idx = Int(house.typeID)
    guard idx >= 0, idx < HousePool.capacity else { continue }
    // allocate if not yet used
    var h = houses[idx]
    h.credits = UInt16(clamping: layout.credits)
    h.creditsQuota = UInt16(clamping: layout.quota)
    houses[idx] = h
}
```

`creditsStorage` stays `0` on the scenario path — scenarios don't specify storage cap; it's derived at runtime from refinery count.

## 3. Save-path plumbing

`Formats.Save.Players.Slot` already decodes all three fields. `WorldSnapshot.init(loading:baseline:)` copies them verbatim into the pool slot:

```swift
var h = houses[idx]
h.starportLinkedID = slot.starportLinkedID
h.credits = slot.credits
h.creditsStorage = slot.creditsStorage
h.creditsQuota = slot.creditsQuota
houses[idx] = h
```

## 4. What slice 6a does NOT cover

- **Credit drain during BUSY** — the construction cost formula `buildCost × tick / buildTime` + per-tick deduction is slice 6b.
- **Cancel refund** — proportional refund on `cancelConstruction` lives with the drain in slice 6b.
- **Storage cap enforcement** — a house's `credits` can go above `creditsStorage` today (nothing blocks it). Slice 6b adds the cap.
- **Harvester → refinery income** — the other side of the economy. Deferred until P5 HUD.
- **HUD rendering** — slice 6c adds the "Credits: N" label on `ScenarioScene`.
- **`creditsStorage` runtime computation** from refinery count. We store the save's value and trust it; live refreshes come with the HUD slice.

## 5. Testing

Extend `SimulationWorldSnapshotTests` + add scenario-specific tests where needed:

- Default `HouseSlot` has all three credit fields at `0`.
- Scenario init: `scenario.houses[atreides] = HouseLayout(quota: 5000, credits: 2000, brain: .human, maxUnits: 20)` → `snapshot.houses[atreides].credits == 2000`, `creditsQuota == 5000`.
- Save init: real `_SAVE001.DAT` load → `snapshot.houses[humanSlot].credits == game.houses.humanSlot.credits` (per-slot cross-check against the save record).
- Storage round-trip from save.

## 6. Cross-link

- `Code/Core/Sources/DuneIICore/Simulation/HousePool.swift` — three new fields + updated init.
- `Code/Core/Sources/DuneIICore/Simulation/WorldSnapshot.swift` — both init paths seed credits.
- `Code/Core/Tests/DuneIICoreTests/SimulationWorldSnapshotTests.swift` — round-trip coverage.
