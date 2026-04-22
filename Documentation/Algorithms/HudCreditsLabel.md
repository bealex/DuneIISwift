# HUD credits label (P5 slice 6d)

Smallest possible visual surface for the credits state that's been live in `HouseSlot.credits` since slice 6a (and drained per tick by 6b/6c). After this slice the player can finally *see* their economy ticking.

## Goal

A "Credits: N" label rendered on the `ScenarioScene`, refreshed every tick so the user sees credits drain (BUSY yards) and refund (cancel) in real time.

Deferred:

- Spice / silo capacity readout — needs `creditsStorage` to be live (computed from refinery + silo count, not yet wired).
- Per-house display when spectating an enemy yard. (Spectating doesn't exist; punted.)
- Animation on credit change — number just updates; no roll-up tweens.
- Quota/score display.

## Reference

`HouseSlot.credits` is the single source of truth. It's drained / refunded by `Structures.tickConstruction` / `cancelConstruction` (slice 6b, 6c) and seeded from `Scenario.HouseLayout.credits` (slice 6a) — mission 1's `[Atreides]` block has `Credits=1000`, so the HUD will start at 1000 and tick down as yards work. OpenDUNE's matching surface is `widget_draw.c:GUI_Widget_Credits_Display`, but its visual treatment (digit roll-up, spice column) is presentation-only and not in scope here.

## Architecture

Two changes, both small.

### Pure-sim helper: `Simulation.House.credits(for:in:)`

Existing `Simulation.House` namespace gains:

```swift
public static func credits(for houseID: UInt8, in pool: HousePool) -> UInt16?
```

Returns the slot's `credits` when the houseID is in range and `slot.isUsed`; `nil` otherwise. The `nil` return distinguishes "no such house" from "house has zero credits" — the HUD shows "—" for the former and "0" for the latter.

This is one line of logic that does not strictly need its own namespace member, but pulling it out keeps the SpriteKit code free of `houses.slots[Int(playerHouseID)].credits` indexing and gives us a clean test target.

### Scene: `ScenarioScene.creditsLabel`

A second `SKLabelNode` parented to the scene, anchored at the top of the right-hand sidebar (above the `BUILD` header). Refreshed each tick from `Simulation.House.credits(for: playerHouseID, in: host.houses)`. When `nil` (player house not allocated — shouldn't happen on a real scenario, but defensive), shows "Credits: —".

Position: `x = mapSize + sidebarWidth / 2`, `y = mapSize - 10` (8 pt below the top edge, matching the BUILD header's typography). White text, `fontSize = 14`. Anchored centered, zPosition 10 (above sidebar background, same plane as BUILD header).

Refresh hook: piggybacks on existing `refreshHud()` which already runs each tick from `update(_:)` after `scheduler.tick()`.

## Tests

`HouseCreditsLookupTests.swift` (pure-sim, synthetic pool):

- Allocated house with non-zero credits → returns the value.
- Allocated house with zero credits → returns 0 (not nil).
- Unallocated slot → returns nil.
- Out-of-range houseID (`6`, `0xFF`) → returns nil.

No SpriteKit tests — the label's layout is visually-verified per the manual checklist.

## Manual verification

`swift run duneii`, mission-1 Atreides:

1. Scenario loads. Top-right corner above BUILD header reads `Credits: 1000`.
2. Click WINDTRAP row → BUSY → number ticks down by `buildCredits/buildTime` each sim-tick (300 / 24 = 12 credits per tick at 12 Hz).
3. Cancel a BUSY yard → credits refund proportional to remaining countdown.
4. Build a structure to completion → credits don't drop further past total cost.

## File inventory

New:

- `Code/Core/Tests/DuneIICoreTests/HouseCreditsLookupTests.swift`

Modified:

- `Code/Core/Sources/DuneIICore/Simulation/House.swift` — add `credits(for:in:)`.
- `Code/Core/Sources/DuneIIRendering/Scene/ScenarioScene.swift` — add `creditsLabel`, set up in `addHud()`, refresh in `refreshHud()`.

## Acceptance

- New tests green.
- Full suite green with zero warnings on a clean build.
- Manual verification per checklist.
- History entry + `CurrentState.md` bump.
