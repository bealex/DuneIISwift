# Starport / CHOAM cart — slice 5c

Status: Drafted 2026-04-23 (STARPORT slice 5c-ui — closes the CHOAM arc after 5a INI load + 5b sim-side delivery loop).

Slices 5a / 5b / 5c-sim landed the INI parser, the live stock vector on `Scheduler.starportStock`, the frigate delivery timer, and the pure `StarportController` cart state machine. This slice (5c-ui) wires the controller into `ScenarioScene` so the player sees a CHOAM panel when they left-click a friendly STARPORT and can add items, see credits drain in real time, and commit (or cancel) the order.

References:

- `Documentation/Algorithms/FactoryBuildable.md` — parallel sidebar (BUILD) pattern this mimics.
- OpenDUNE `src/gui/gui.c:2726..2798` — factory-window CHOAM mode, pricing, cart.
- OpenDUNE `src/structure.c:1583..1632` — order commit (cart → chain units + stock drain).

## 1. Architecture split

Three layers already exist before this slice; slice 5c-ui adds the scene layer only.

| Layer | File | What it does |
|---|---|---|
| Sim | `Simulation/Structures.swift` | `commitStarportOrder(houseID:orders:houses:units:stock:deliveryTime:)` (pure). Writes off-map units into `UnitPool`, chains them onto `HouseSlot.starportLinkedID`, decrements `stock`. |
| Sim | `Simulation/Scheduler.swift` | `tickStarportDelivery` + `tickStarportAvailability` + `starportStock` (already in 5b). |
| Controller | `DuneIIRendering/Scene/StarportController.swift` | Pure cart state machine. `open(...)` computes per-session prices, `increment` / `decrement` track cart + virtual credit drain, `pendingOrders()` emits the commit payload. |
| **Scene (new)** | `DuneIIRendering/Scene/ScenarioScene.swift` + `ScenarioRuntime.swift` | STARPORT click detection, sidebar rendering in CHOAM mode, click-to-button routing, commit pipeline. |

## 2. Runtime additions (`ScenarioRuntime`)

- `public var starportController: StarportController?` — live panel state. `nil` when no panel is open.
- New `ClickOutcome` cases: `.starportOpened(structureIndex:)`, `.starportCartUpdated`, `.starportCommitted(chained:)`, `.starportCancelled`.
- `leftClick(tileX:tileY:)` step 2 (structure select) detects a friendly STARPORT (type 11, `houseID == playerHouseID`) and instantiates the controller via `StarportController.open(...)`. Clicking a non-starport structure while a panel is live drops it (click-away cancel). `buildController.selectedYardIndex` is force-cleared on open so the sidebar flips cleanly to CHOAM mode.
- Four new mutation entry points: `starportIncrement(typeID:)`, `starportDecrement(typeID:)`, `starportCommit()`, `starportCancel()`. `commit` calls `Simulation.Structures.commitStarportOrder`, writes `controller.availableCredits` back to the house (applying the virtual drain), and clears the controller. `cancel` drops the controller without writing anything — credits auto-refund because the cart-drain was never persisted.

## 3. Scene rendering (`ScenarioScene`)

`refreshBuildSidebar()` branches: if `runtime.starportController != nil`, call `renderStarportPanel()` instead of `renderSidebar()`. The panel layout reuses `sidebarRowHeight` + `sidebarPadding`:

- **Header** "CHOAM" in yellow-gold, centered at the sidebar top.
- **Rows** (one per `controller.rows[i]`):
  - Left: house-coloured unit sprite (20×20) via `unitAtlas?.texture(at:houseID:)` using `UnitInfo.groundSpriteID`.
  - Middle: short unit name + `"$<price>"` stacked.
  - Right: `"<inCart>←<stockRemaining>"` when `inCart > 0` (green), else `"·<stockRemaining>"` (grey).
  - Row background dims yellow when the cart count is non-zero.
- **Separator gap** (6 pt).
- **Display rows**: `"CREDITS $<availableCredits>"` (white) and `"TOTAL $<cartTotal>"` (gold).
- **SEND button**: dark green fill + bright green stroke.
- **CANCEL button**: dark red fill + bright red stroke.
- **Info panel**: existing `renderInfoPanel(into:)` still drawn at the bottom so selection details (the STARPORT's HP, state, etc.) stay visible.

## 4. Click routing

`mouseDown(with:)` checks `runtime.starportController != nil` AND `location.x >= sidebarX` and — when both true — calls `starportHitTest(atY:x:)` before any standard click classification. The hit test returns one of:

- `.decrement(rowIndex:)` — click landed on the left half of a row.
- `.increment(rowIndex:)` — right half of a row.
- `.send` — SEND button.
- `.cancel` — CANCEL button.
- `nil` — CREDITS / TOTAL rows or padding (no-op).

Each hit routes to the matching runtime method. Map clicks fall through unchanged — clicking a non-starport map tile drops the panel via the `leftClick` step-2 `clicked-away` branch.

## 5. Manual verification checklist

Scene-level visual correctness can't be asserted from CI (the sandbox can't drive SpriteKit), so the following checklist stands in. Run with a scenario that has a player-owned STARPORT (build one, or hand-edit a test scenario's `[STRUCTURES]` block).

### Golden path

- [ ] Player builds a STARPORT via the BUILD sidebar. Left-click it → sidebar flips from BUILD to CHOAM. "CHOAM" header visible, rows populated with seeded stock.
- [ ] Click the right half of a row → in-cart count bumps 0 → 1, `CREDITS` drops by exactly `unitPrice`, `TOTAL` bumps by the same amount.
- [ ] Click the right half of the same row four more times → count reaches 5, credits keep dropping, total rising.
- [ ] Click the left half of that row → count drops 5 → 4, credits refund, total decreases.
- [ ] Click SEND → panel closes, sidebar returns to BUILD mode, `CREDITS` line in HUD now reflects the drained balance, waiting units start appearing as the delivery timer counts down (at the default cadence, ~5 s per tick-cycle → frigate lands after `starportDeliveryTimeByHouse[0..2] = 10` ticks).
- [ ] After the frigate lands, ordered units should materialise on the STARPORT's tile (script-driven drop animation is deferred to the post-slice-5 follow-up — for now, the chained units are allocated off-map and remain `inTransport`).

### Edge cases

- [ ] Click a row whose `stockRemaining == 0` → increment no-ops (no visual change to the cart count, no credit drain).
- [ ] Click `+` repeatedly until credits can no longer cover the next unit → further `+` clicks no-op.
- [ ] Click `−` on a row whose cart count is already 0 → no-op (count stays 0, no visual glitch).
- [ ] Click CANCEL → panel closes, credits return to their pre-panel value, stock counts return to the pre-panel values (cart rows were virtual until SEND).
- [ ] Click CANCEL on an empty cart → panel closes with no state changes.
- [ ] Click SEND on an empty cart → behaves identically to CANCEL (no commit, no drain).
- [ ] While the CHOAM panel is open, left-click a friendly CYARD → panel closes, sidebar flips to BUILD mode for that yard.
- [ ] While the panel is open, left-click a map tile with no structure → panel closes.
- [ ] Open panel, increment 2 items, click a different STARPORT on the map → panel reopens with fresh prices + stock; the previous cart is discarded (credits restored).
- [ ] The price column stays stable within one session (prices are seeded once at `open` via `BorlandLCG`; subsequent mutations don't re-roll).

### Multi-player-house scenarios

- [ ] Load a scenario where the player is Ordos. Stock a Launcher in `[CHOAM]`. Open the CHOAM panel → Launcher row does NOT appear (blocked by `UnitInfo.availableHouse` bit 2). Stock a Quad → Quad row DOES appear (Quad has the all-houses bitmask).

### Layout integrity

- [ ] The existing BUILD sidebar still works correctly after a STARPORT click is cancelled. No visual lingering of the CHOAM panel's yellow header or row backgrounds.
- [ ] Info panel at the bottom of the sidebar keeps showing the selected structure's name + HP while the CHOAM panel is open (the panel renders above the info panel region).
- [ ] Minimap keeps rendering (not obscured by the panel).

## 6. Known follow-ups

- **Frigate landing animation + cargo drop** — currently we allocate off-map units with `inTransport = true`; the script-driven landing sequence that lowers the frigate, unloads the units one by one, and positions them next to the starport is unported. This is a script-layer concern (the FRIGATE unit has its own EMC entry) and sits naturally after the generic script dispatch.
- **Pricing seed parity** — OpenDUNE seeds from `((timerGame - tickScenarioStart) / 60 / 60) + scenarioID + playerHouseID`, then squares it. Our seed uses `tickCounter + playerHouseID + (scenarioName.hashValue)` which is deterministic but not byte-exact with the original. Fine for now; parity can tighten when the tick-parity golden harness lands.
- **Cart-row sorting** — we walk `starportStock` in ascending unit-type order. OpenDUNE's factory window sorts by `sortPriority`. Cosmetic difference; revisit if the sidebar's row ordering feels off during playtest.

## 7. Test coverage

- `StarportControllerTests` (14 tests) — pricing determinism / bounds, open filter, cart drain/refund semantics.
- `StarportDeliveryTests` (12 tests) — `commitStarportOrder` topology, `tickStarportDelivery` countdown + FRIGATE spawn, `tickStarportAvailability` bump rules.
- `ScenarioRuntimeTests`:
  - `leftClick on friendly STARPORT opens the cart; commit drains credits, chains units, and decrements stock` — end-to-end flow, real mission-1 load + hand-stamped STARPORT.
  - `starportCancel drops the panel without touching credits or stock` — cancel semantics.
- Scene rendering is manual; see §5.
