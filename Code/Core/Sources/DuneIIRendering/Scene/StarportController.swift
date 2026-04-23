import Foundation
import DuneIICore

/// Pure state machine for the STARPORT cart panel (slice 5c). Mirrors
/// the split used by `BuildPanelController` / `UnitCommandController`:
/// the controller holds all cart state + pricing + credit math, the
/// scene renders it and pipes `NSEvent`s in as abstract clicks.
///
/// Lifecycle:
/// 1. Scene detects a friendly STARPORT left-click → instantiates a
///    controller via `open(...)` with the live stock vector, the
///    house's credits, the per-unit `buildCredits`, and an RNG seed
///    derived from scenario clock + scenario ID + player house ID
///    (port of `GUI_FactoryWindow_InitItems` seed math at
///    `src/gui/gui.c:2749..2754`). `open` also computes per-unit
///    prices once — they stay stable for the life of the panel.
/// 2. Scene dispatches `.increment(typeID)` / `.decrement(typeID)` as
///    the player clicks "+" / "−" on each row. Each mutation drains
///    (or refunds) the house's `credits` balance tracked on the
///    controller; the scene reads `available` for display.
/// 3. Scene calls `send(...)` to commit the cart. The controller
///    returns an `Order` list the scene feeds to
///    `Simulation.Structures.commitStarportOrder(...)`. `cancel()`
///    discards the cart and refunds credits.
///
/// The controller is value-typed + `Sendable`; no SpriteKit references.
public struct StarportController: Sendable, Equatable {

    /// A single buy line in the cart panel.
    public struct Row: Sendable, Equatable {
        public let typeID: UInt8
        /// Per-unit price computed once at `open` from
        /// `UnitInfo.buildCredits` and the per-session RNG. Fixed for
        /// the life of the panel.
        public let unitPrice: UInt16
        /// In-stock count at panel-open time, decremented by adds.
        public var stockRemaining: Int16
        /// Units in the cart right now (0 = nothing added yet).
        public var inCart: UInt16

        public init(typeID: UInt8, unitPrice: UInt16, stockRemaining: Int16, inCart: UInt16 = 0) {
            self.typeID = typeID
            self.unitPrice = unitPrice
            self.stockRemaining = stockRemaining
            self.inCart = inCart
        }
    }

    /// Commit payload returned by `send()`. Consumer hands this to
    /// `Simulation.Structures.commitStarportOrder` after validating
    /// total credits + unit-pool capacity.
    public struct Order: Sendable, Equatable {
        public let typeID: UInt8
        public let count: Int
    }

    public let houseID: UInt8
    public let starportIndex: Int
    public private(set) var rows: [Row]
    /// House credits *with the current cart already subtracted*. The
    /// scene renders this so the player sees live remaining cash.
    public private(set) var availableCredits: UInt16
    /// Sum of per-row `inCart * unitPrice` — regenerated on every
    /// mutation so the scene can display a running total.
    public private(set) var cartTotal: UInt16

    /// Builds the starport panel. `houseCredits` is the house's cash
    /// at panel-open time; `stock` is a copy of the live
    /// `Scheduler.starportStock` for the relevant house; `priceSeed`
    /// feeds a `BorlandLCG` so all prices are deterministic per
    /// session (port of `src/gui/gui.c:2749..2754`).
    public static func open(
        houseID: UInt8,
        starportIndex: Int,
        houseCredits: UInt16,
        stock: [Int16],
        priceSeed: UInt16
    ) -> StarportController {
        var rng = RNG.BorlandLCG(seed: priceSeed)
        var rows: [Row] = []
        let houseBit = UInt8(1) << houseID
        for (typeIDRaw, count) in stock.enumerated() {
            guard count > 0 else { continue }
            let typeID = UInt8(truncatingIfNeeded: typeIDRaw)
            guard let info = Simulation.UnitInfo.lookup(typeID) else { continue }
            if (info.availableHouse & houseBit) == 0 { continue }
            let price = calculateStarportPrice(buildCredits: info.buildCredits, rng: &rng)
            rows.append(Row(typeID: typeID, unitPrice: price, stockRemaining: count))
        }
        return StarportController(
            houseID: houseID,
            starportIndex: starportIndex,
            rows: rows,
            availableCredits: houseCredits,
            cartTotal: 0
        )
    }

    public init(
        houseID: UInt8, starportIndex: Int,
        rows: [Row], availableCredits: UInt16, cartTotal: UInt16
    ) {
        self.houseID = houseID
        self.starportIndex = starportIndex
        self.rows = rows
        self.availableCredits = availableCredits
        self.cartTotal = cartTotal
    }

    /// CHOAM price formula. Port of OpenDUNE
    /// `GUI_FactoryWindow_CalculateStarportPrice` (`src/gui/gui.c:2726`):
    /// `credits = (bc / 10) * 4 + (bc / 10) * (rng(0..6) + rng(0..6))`,
    /// clamped at 999. Called twice per invocation to consume exactly
    /// two RNG draws, matching OpenDUNE's sequence.
    public static func calculateStarportPrice(
        buildCredits: UInt16, rng: inout RNG.BorlandLCG
    ) -> UInt16 {
        let perTen = buildCredits / 10
        let multiplier = rng.range(0, 6) &+ rng.range(0, 6)
        let value = UInt32(perTen) &* 4 &+ UInt32(perTen) &* UInt32(multiplier)
        return UInt16(min(value, 999))
    }

    /// Add one unit of `typeID` to the cart. Fails (`false`) when:
    /// - the row doesn't exist,
    /// - its `stockRemaining == 0`,
    /// - the house can't afford the unit price.
    @discardableResult
    public mutating func increment(typeID: UInt8) -> Bool {
        guard let rowIdx = rows.firstIndex(where: { $0.typeID == typeID }) else { return false }
        var row = rows[rowIdx]
        guard row.stockRemaining > 0 else { return false }
        guard availableCredits >= row.unitPrice else { return false }
        row.inCart &+= 1
        row.stockRemaining -= 1
        rows[rowIdx] = row
        availableCredits &-= row.unitPrice
        cartTotal &+= row.unitPrice
        return true
    }

    /// Remove one unit of `typeID` from the cart. No-ops (`false`)
    /// when the row doesn't exist or has 0 in-cart.
    @discardableResult
    public mutating func decrement(typeID: UInt8) -> Bool {
        guard let rowIdx = rows.firstIndex(where: { $0.typeID == typeID }) else { return false }
        var row = rows[rowIdx]
        guard row.inCart > 0 else { return false }
        row.inCart &-= 1
        row.stockRemaining += 1
        rows[rowIdx] = row
        availableCredits &+= row.unitPrice
        cartTotal &-= row.unitPrice
        return true
    }

    /// Cart snapshot suitable for `Simulation.Structures.commitStarportOrder`.
    /// Empty rows are dropped. The consumer passes this plus the
    /// (original, not `availableCredits`) house state to the commit
    /// helper — credit drain happens via the controller's tracked
    /// subtraction, which the scene applies once on `send`.
    public func pendingOrders() -> [Order] {
        rows.compactMap { $0.inCart > 0 ? Order(typeID: $0.typeID, count: Int($0.inCart)) : nil }
    }
}
