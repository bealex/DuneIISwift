import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

/// STARPORT slice 5c — `StarportController` state machine + pricing
/// formula. Pins the per-session price derivation (OpenDUNE
/// `GUI_FactoryWindow_CalculateStarportPrice` at `src/gui/gui.c:2726`)
/// and the cart-drain / refund behaviour the scene relies on.
@MainActor
@Suite("StarportController — cart state + pricing")
struct StarportControllerTests {

    private let TRIKE: UInt8 = 13
    private let TANK: UInt8 = 9
    private let LAUNCHER: UInt8 = 7

    // MARK: - Pricing formula

    @Test("calculateStarportPrice: deterministic for a given seed")
    func pricingDeterministic() {
        var rng1 = RNG.BorlandLCG(seed: 42)
        var rng2 = RNG.BorlandLCG(seed: 42)
        let p1 = StarportController.calculateStarportPrice(buildCredits: 300, rng: &rng1)
        let p2 = StarportController.calculateStarportPrice(buildCredits: 300, rng: &rng2)
        #expect(p1 == p2, "same seed must yield the same price")
    }

    @Test("calculateStarportPrice: minimum is (bc / 10) * 4 — both rng draws are zero")
    func pricingHitsLowerBound() {
        // We can't easily force the LCG to draw two zeros without
        // custom seeding; instead check the formula's lower bound
        // directly. `(300 / 10) * 4 = 120`.
        var rng = RNG.BorlandLCG(seed: 1)
        var minPrice: UInt16 = .max
        for _ in 0..<128 {
            let p = StarportController.calculateStarportPrice(buildCredits: 300, rng: &rng)
            if p < minPrice { minPrice = p }
        }
        #expect(minPrice >= 120, "per-ten × 4 is the structural floor")
    }

    @Test("calculateStarportPrice: caps at 999 — large buildCredits saturate")
    func pricingCapsAt999() {
        var rng = RNG.BorlandLCG(seed: 99)
        // buildCredits = 2000 → perTen = 200, floor = 800, max = 800 +
        // 200*(6+6) = 800 + 2400 = 3200 → capped to 999.
        for _ in 0..<32 {
            let p = StarportController.calculateStarportPrice(buildCredits: 2000, rng: &rng)
            #expect(p <= 999, "price must saturate at 999; got \(p)")
        }
    }

    @Test("calculateStarportPrice: consumes exactly two RNG draws per call")
    func pricingConsumesTwoDraws() {
        var rng1 = RNG.BorlandLCG(seed: 7)
        // Baseline: pull 4 values from the same seed.
        _ = rng1.range(0, 6); _ = rng1.range(0, 6)
        _ = rng1.range(0, 6); _ = rng1.range(0, 6)
        let baselineState = rng1.state

        var rng2 = RNG.BorlandLCG(seed: 7)
        _ = StarportController.calculateStarportPrice(buildCredits: 100, rng: &rng2)
        _ = StarportController.calculateStarportPrice(buildCredits: 100, rng: &rng2)
        #expect(rng2.state == baselineState,
                "two price calls must consume exactly four rng.range draws")
    }

    // MARK: - open(...)

    @Test("open: builds one row per listed + house-allowed unit type")
    func openFiltersByAvailableHouse() {
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TRIKE)] = 5
        stock[Int(TANK)] = 4
        stock[Int(LAUNCHER)] = 3
        // Ordos is missing from Launcher's availableHouse bitmask +
        // Ordos can't field vanilla Trike (substitution unresolved at
        // the CHOAM layer). So Ordos only sees Tank; Atreides sees
        // Trike + Tank + Launcher.
        let atr = StarportController.open(
            houseID: Simulation.House.atreides, starportIndex: 0,
            houseCredits: 2000, stock: stock, priceSeed: 1234
        )
        let ord = StarportController.open(
            houseID: Simulation.House.ordos, starportIndex: 0,
            houseCredits: 2000, stock: stock, priceSeed: 1234
        )
        #expect(atr.rows.map(\.typeID).sorted() == [TANK, TRIKE, LAUNCHER].sorted())
        #expect(ord.rows.map(\.typeID) == [TANK])
    }

    @Test("open: stock == 0 and stock == -1 omit the row")
    func openSkipsZeroAndMinusOneStock() {
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TRIKE)] = -1
        stock[Int(TANK)] = 0
        stock[Int(LAUNCHER)] = 2
        let c = StarportController.open(
            houseID: Simulation.House.atreides, starportIndex: 0,
            houseCredits: 2000, stock: stock, priceSeed: 77
        )
        #expect(c.rows.map(\.typeID) == [LAUNCHER])
    }

    @Test("open: availableCredits = houseCredits, cartTotal = 0")
    func openInitialState() {
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TRIKE)] = 5
        let c = StarportController.open(
            houseID: Simulation.House.atreides, starportIndex: 0,
            houseCredits: 2500, stock: stock, priceSeed: 1
        )
        #expect(c.availableCredits == 2500)
        #expect(c.cartTotal == 0)
        #expect(c.rows.count == 1)
        #expect(c.rows[0].inCart == 0)
        #expect(c.rows[0].stockRemaining == 5)
    }

    // MARK: - increment / decrement

    @Test("increment: drains credits, decrements stockRemaining, bumps cartTotal")
    func incrementDrainsAndTracks() {
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TRIKE)] = 5
        var c = StarportController.open(
            houseID: Simulation.House.atreides, starportIndex: 0,
            houseCredits: 10000, stock: stock, priceSeed: 5
        )
        let price = c.rows[0].unitPrice
        let ok1 = c.increment(typeID: TRIKE)
        #expect(ok1)
        #expect(c.rows[0].inCart == 1)
        #expect(c.rows[0].stockRemaining == 4)
        #expect(c.cartTotal == price)
        #expect(c.availableCredits == 10000 - price)
        let ok2 = c.increment(typeID: TRIKE)
        #expect(ok2)
        #expect(c.rows[0].inCart == 2)
        #expect(c.cartTotal == price * 2)
        #expect(c.availableCredits == 10000 - price * 2)
    }

    @Test("increment: refused when stock is exhausted")
    func incrementStops_atStock() {
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TRIKE)] = 2
        var c = StarportController.open(
            houseID: Simulation.House.atreides, starportIndex: 0,
            houseCredits: 10000, stock: stock, priceSeed: 5
        )
        let ok1 = c.increment(typeID: TRIKE); #expect(ok1)
        let ok2 = c.increment(typeID: TRIKE); #expect(ok2)
        let ok3 = c.increment(typeID: TRIKE)
        #expect(!ok3, "3rd increment must fail on 2-item stock")
        #expect(c.rows[0].inCart == 2)
    }

    @Test("increment: refused when house can't afford the unit")
    func incrementStops_atCredits() {
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TANK)] = 5
        var c = StarportController.open(
            houseID: Simulation.House.atreides, starportIndex: 0,
            houseCredits: 50, stock: stock, priceSeed: 1
        )
        let ok = c.increment(typeID: TANK)
        #expect(!ok,
                "tank floor is 800/10 * 4 = 320; 50 credits can't cover")
        #expect(c.cartTotal == 0)
        #expect(c.availableCredits == 50)
    }

    @Test("decrement: refunds credits, restores stockRemaining, drops cartTotal")
    func decrementRefunds() {
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TRIKE)] = 3
        var c = StarportController.open(
            houseID: Simulation.House.atreides, starportIndex: 0,
            houseCredits: 10000, stock: stock, priceSeed: 5
        )
        let price = c.rows[0].unitPrice
        _ = c.increment(typeID: TRIKE)
        _ = c.increment(typeID: TRIKE)
        let ok = c.decrement(typeID: TRIKE)
        #expect(ok)
        #expect(c.rows[0].inCart == 1)
        #expect(c.rows[0].stockRemaining == 2)
        #expect(c.cartTotal == price)
        #expect(c.availableCredits == 10000 - price)
    }

    @Test("decrement: refused when cart is empty for that type")
    func decrementStops_atEmptyCart() {
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TRIKE)] = 5
        var c = StarportController.open(
            houseID: Simulation.House.atreides, starportIndex: 0,
            houseCredits: 10000, stock: stock, priceSeed: 5
        )
        let ok = c.decrement(typeID: TRIKE)
        #expect(!ok)
        #expect(c.rows[0].inCart == 0)
    }

    // MARK: - pendingOrders()

    @Test("pendingOrders: drops zero-cart rows; preserves row order")
    func pendingOrdersDropsEmpty() {
        var stock = [Int16](repeating: 0, count: 27)
        stock[Int(TRIKE)] = 5
        stock[Int(TANK)] = 5
        stock[Int(LAUNCHER)] = 5
        var c = StarportController.open(
            houseID: Simulation.House.atreides, starportIndex: 0,
            houseCredits: 60_000, stock: stock, priceSeed: 5
        )
        _ = c.increment(typeID: TRIKE)
        _ = c.increment(typeID: LAUNCHER)
        _ = c.increment(typeID: LAUNCHER)
        // TANK left at 0 in cart.
        let orders = c.pendingOrders()
        #expect(orders.count == 2)
        // `open()` walks `stock.enumerated()` in ascending unit-type
        // order, so rows are [LAUNCHER(7), TANK(9), TRIKE(13)]. TANK
        // is filtered out (inCart=0); the survivors stay in that order.
        #expect(orders[0].typeID == LAUNCHER && orders[0].count == 2)
        #expect(orders[1].typeID == TRIKE && orders[1].count == 1)
    }

    // MARK: - ScenarioRuntime → Scheduler.starportStock wiring

    @Test("ScenarioRuntime.load seeds Scheduler.starportStock from scenario CHOAM INI")
    func scenarioRuntimeSeedsStarportStock() throws {
        // Full install is required to resolve the PAK'd scenario;
        // short-circuit when it's absent.
        guard let installDir = TestInstall.locate() else { return }
        let installation = try Installation(rootDirectory: installDir)
        let assets = try AssetLoader(installation: installation)
        let runtime = ScenarioRuntime(assets: assets)
        // SCENA015 ships [CHOAM] (Trike=5, Quad=5, Tank=4, Launcher=3,
        // Harvester=2, MCV=2, Carryall=2). Skip if the install omits it.
        do {
            try runtime.load(scenarioName: "SCENA015.INI")
        } catch {
            return
        }
        let stock = runtime.scheduler?.starportStock ?? []
        #expect(stock.count == 27)
        #expect(stock[Int(UnitType.trike.typeID)] == 5)
        #expect(stock[Int(UnitType.tank.typeID)] == 4)
        #expect(stock[Int(UnitType.harvester.typeID)] == 2)
    }
}
