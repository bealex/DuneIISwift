import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

/// Tests for `UnitCommandController` — the pure state machine that sits
/// between `ScenarioScene` mouse events and the pool. Lives alongside
/// `BuildPanelController` in the Rendering library; tested here so it's
/// exercised by the same `swift test` pass.
@Suite("UnitCommandController — left-click select / right-click move order")
struct UnitCommandControllerTests {

    private static let playerHouse: UInt8 = Simulation.House.atreides

    /// Synthetic 64×64 pool with one Atreides trike on tile (10, 10),
    /// one Harkonnen trike on tile (20, 20), and nothing else. Returns
    /// the pool + both pool indices.
    private static func makePool() -> (pool: Simulation.UnitPool, friendly: Int, enemy: Int) {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 0, type: 13, houseID: Simulation.House.atreides)
        _ = pool.allocate(at: 1, type: 13, houseID: Simulation.House.harkonnen)
        var u0 = pool[0]
        u0.positionX = 10 * 256 + 128
        u0.positionY = 10 * 256 + 128
        pool[0] = u0
        var u1 = pool[1]
        u1.positionX = 20 * 256 + 128
        u1.positionY = 20 * 256 + 128
        pool[1] = u1
        return (pool, 0, 1)
    }

    @Test("initial state has no selection")
    func initialState() {
        let controller = UnitCommandController()
        #expect(controller.selectedUnitIndex == nil)
    }

    @Test("left-click on friendly unit → .selectUnit")
    func leftClickFriendly() {
        let (pool, friendly, _) = Self.makePool()
        var controller = UnitCommandController()
        let action = controller.handle(
            click: .leftMapTile(x: 10, y: 10),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .selectUnit(poolIndex: friendly))
        #expect(controller.selectedUnitIndex == friendly)
    }

    @Test("left-click on enemy unit with nothing selected → .none")
    func leftClickEnemy() {
        let (pool, _, _) = Self.makePool()
        var controller = UnitCommandController()
        let action = controller.handle(
            click: .leftMapTile(x: 20, y: 20),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .none)
        #expect(controller.selectedUnitIndex == nil)
    }

    @Test("left-click on empty tile with no selection → .none")
    func leftClickEmptyNoSelection() {
        let (pool, _, _) = Self.makePool()
        var controller = UnitCommandController()
        let action = controller.handle(
            click: .leftMapTile(x: 5, y: 5),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .none)
    }

    @Test("left-click on empty tile with a selection → .deselect")
    func leftClickEmptyWithSelection() {
        let (pool, friendly, _) = Self.makePool()
        var controller = UnitCommandController(selectedUnitIndex: friendly)
        let action = controller.handle(
            click: .leftMapTile(x: 5, y: 5),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .deselect)
        #expect(controller.selectedUnitIndex == nil)
    }

    @Test("left-click on different friendly unit → switches selection")
    func leftClickSwitchSelection() {
        var pool = Self.makePool().pool
        // Add a second friendly at (30, 30).
        _ = pool.allocate(at: 2, type: 13, houseID: Simulation.House.atreides)
        var u2 = pool[2]
        u2.positionX = 30 * 256 + 128
        u2.positionY = 30 * 256 + 128
        pool[2] = u2

        var controller = UnitCommandController(selectedUnitIndex: 0)
        let action = controller.handle(
            click: .leftMapTile(x: 30, y: 30),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .selectUnit(poolIndex: 2))
        #expect(controller.selectedUnitIndex == 2)
    }

    @Test("right-click on map with no selection → .none")
    func rightClickNoSelection() {
        let (pool, _, _) = Self.makePool()
        var controller = UnitCommandController()
        let action = controller.handle(
            click: .rightMapTile(x: 40, y: 40),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .none)
    }

    @Test("right-click on map with a selection → .orderMove")
    func rightClickOrderMove() {
        let (pool, friendly, _) = Self.makePool()
        var controller = UnitCommandController(selectedUnitIndex: friendly)
        let action = controller.handle(
            click: .rightMapTile(x: 40, y: 40),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .orderMove(poolIndex: friendly, tileX: 40, tileY: 40))
        // Selection persists after a move order — user can chain orders.
        #expect(controller.selectedUnitIndex == friendly)
    }

    @Test("selection auto-clears when the selected slot has been freed")
    func staleSelectionAutoClears() {
        var (pool, friendly, _) = Self.makePool()
        var controller = UnitCommandController(selectedUnitIndex: friendly)
        pool.free(at: friendly)

        // Any subsequent click with a stale selection drops it.
        let action = controller.handle(
            click: .leftMapTile(x: 5, y: 5),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(controller.selectedUnitIndex == nil)
        // With the stale selection cleared and no unit under the click
        // target, this collapses to .none.
        #expect(action == .none)
    }

    @Test("right-click with a freed selection drops the selection, does not issue orderMove")
    func rightClickWithFreedSelection() {
        var (pool, friendly, _) = Self.makePool()
        var controller = UnitCommandController(selectedUnitIndex: friendly)
        pool.free(at: friendly)
        let action = controller.handle(
            click: .rightMapTile(x: 40, y: 40),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(controller.selectedUnitIndex == nil)
        #expect(action == .none)
    }
}
