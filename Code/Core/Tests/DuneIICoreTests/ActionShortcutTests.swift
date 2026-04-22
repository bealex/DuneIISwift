import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

@Suite("UnitCommandController — A/M/H/R shortcut staging + resolution")
struct ActionShortcutTests {

    private static let playerHouse: UInt8 = Simulation.House.atreides

    /// Pool with: Atreides trike idx=0 at (10,10), Atreides harvester
    /// idx=16 at (12,12), Harkonnen trike idx=1 at (20,20).
    private static func makePool() -> (
        pool: Simulation.UnitPool,
        trike: Int, harvester: Int, enemy: Int
    ) {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 0, type: 13, houseID: Simulation.House.atreides)
        _ = pool.allocate(at: 1, type: 13, houseID: Simulation.House.harkonnen)
        let hIdx = pool.allocate(
            in: 16...19, type: 16 /* HARVESTER */, houseID: Simulation.House.atreides
        )!
        var u0 = pool[0]; u0.positionX = 10 * 256 + 128; u0.positionY = 10 * 256 + 128; pool[0] = u0
        var u1 = pool[1]; u1.positionX = 20 * 256 + 128; u1.positionY = 20 * 256 + 128; pool[1] = u1
        var uh = pool[hIdx]; uh.positionX = 12 * 256 + 128; uh.positionY = 12 * 256 + 128; pool[hIdx] = uh
        return (pool, 0, hIdx, 1)
    }

    @Test("stage rejects when no unit is selected")
    func stageWithoutSelection() {
        var controller = UnitCommandController()
        let (pool, _, _, _) = Self.makePool()
        #expect(controller.stage(action: .attack, pool: pool) == false)
        #expect(controller.stagedAction == nil)
    }

    @Test("stage rejects when selection is enemy (not friendly)")
    func stageWithEnemySelection() {
        var controller = UnitCommandController()
        let (pool, _, _, enemy) = Self.makePool()
        controller.selectedUnitIndex = enemy
        controller.isFriendlySelection = false
        #expect(controller.stage(action: .move, pool: pool) == false)
    }

    @Test("stage .harvest rejects non-harvester selection")
    func stageHarvestOnTrike() {
        var controller = UnitCommandController()
        let (pool, trike, _, _) = Self.makePool()
        controller.selectedUnitIndex = trike
        controller.isFriendlySelection = true
        #expect(controller.stage(action: .harvest, pool: pool) == false)
        #expect(controller.stagedAction == nil)
    }

    @Test("stage .move accepted for a friendly trike")
    func stageMoveAccepted() {
        var controller = UnitCommandController()
        let (pool, trike, _, _) = Self.makePool()
        controller.selectedUnitIndex = trike
        controller.isFriendlySelection = true
        #expect(controller.stage(action: .move, pool: pool) == true)
        #expect(controller.stagedAction == .move)
    }

    @Test("stage .harvest / .return accepted for a harvester")
    func stageHarvesterActions() {
        var controller = UnitCommandController()
        let (pool, _, harvester, _) = Self.makePool()
        controller.selectedUnitIndex = harvester
        controller.isFriendlySelection = true
        #expect(controller.stage(action: .harvest, pool: pool) == true)
        #expect(controller.stage(action: .returnAction, pool: pool) == true)
    }

    @Test("staged .move + left-click issues orderMove and clears the stage")
    func resolveStagedMove() {
        var controller = UnitCommandController()
        let (pool, trike, _, _) = Self.makePool()
        controller.selectedUnitIndex = trike
        controller.isFriendlySelection = true
        _ = controller.stage(action: .move, pool: pool)
        let action = controller.handle(
            click: .leftMapTile(x: 30, y: 30),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .orderMove(poolIndex: trike, tileX: 30, tileY: 30))
        #expect(controller.stagedAction == nil)
        #expect(controller.selectedUnitIndex == trike)
    }

    @Test("staged .attack on an enemy unit tile issues orderAttack")
    func resolveStagedAttackUnit() {
        var controller = UnitCommandController()
        let (pool, trike, _, enemy) = Self.makePool()
        controller.selectedUnitIndex = trike
        controller.isFriendlySelection = true
        _ = controller.stage(action: .attack, pool: pool)
        let action = controller.handle(
            click: .leftMapTile(x: 20, y: 20),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .orderAttack(attackerIndex: trike, targetIndex: enemy))
    }

    @Test("staged .attack on an empty tile falls back to orderMove")
    func resolveStagedAttackEmpty() {
        var controller = UnitCommandController()
        let (pool, trike, _, _) = Self.makePool()
        controller.selectedUnitIndex = trike
        controller.isFriendlySelection = true
        _ = controller.stage(action: .attack, pool: pool)
        let action = controller.handle(
            click: .leftMapTile(x: 40, y: 40),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .orderMove(poolIndex: trike, tileX: 40, tileY: 40))
    }

    @Test("staged .harvest resolves to orderHarvest with the clicked tile")
    func resolveStagedHarvest() {
        var controller = UnitCommandController()
        let (pool, _, harvester, _) = Self.makePool()
        controller.selectedUnitIndex = harvester
        controller.isFriendlySelection = true
        _ = controller.stage(action: .harvest, pool: pool)
        let action = controller.handle(
            click: .leftMapTile(x: 35, y: 35),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .orderHarvest(poolIndex: harvester, tileX: 35, tileY: 35))
    }

    @Test("staged .return resolves to orderReturn (no coord)")
    func resolveStagedReturn() {
        var controller = UnitCommandController()
        let (pool, _, harvester, _) = Self.makePool()
        controller.selectedUnitIndex = harvester
        controller.isFriendlySelection = true
        _ = controller.stage(action: .returnAction, pool: pool)
        let action = controller.handle(
            click: .leftMapTile(x: 35, y: 35),
            pool: pool,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .orderReturn(poolIndex: harvester))
    }

    @Test("stale selection clears an existing stage (defence in depth)")
    func stageStaleClears() {
        var controller = UnitCommandController()
        let (pool, trike, _, _) = Self.makePool()
        controller.selectedUnitIndex = trike
        controller.isFriendlySelection = true
        _ = controller.stage(action: .move, pool: pool)

        // Free the selected unit behind the controller's back.
        var mutated = pool
        mutated.free(at: trike)

        // The subsequent handle() pass should auto-clear the stale
        // selection (existing behaviour) — the stage still lives on
        // the controller but the resolution fallthrough treats the
        // click as a normal select on empty.
        let action = controller.handle(
            click: .leftMapTile(x: 40, y: 40),
            pool: mutated,
            playerHouseID: Self.playerHouse
        )
        #expect(action == .none)
        #expect(controller.selectedUnitIndex == nil)
    }
}
