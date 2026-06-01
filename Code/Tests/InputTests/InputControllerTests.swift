import DuneIIContracts
import Testing
@testable import DuneIIInput

/// `InputController` — the selection + order state machine (the interactive `input → sim` driver). Pure
/// value type, so the click/button → `Command` logic is fully unit-testable without a window.
@Suite("Input controller")
struct InputControllerTests {
    @Test("left-click selects the entity the host resolved there; empty ground deselects")
    func selection() {
        var c = InputController()
        #expect(c.selection == .none)
        c.leftClick(tileX: 5, tileY: 6, hit: .unit(slot: 22))
        #expect(c.selection == .unit(slot: 22))
        c.leftClick(tileX: 9, tileY: 9, hit: .structure(slot: 3))
        #expect(c.selection == .structure(slot: 3))
        c.leftClick(tileX: 0, tileY: 0, hit: .none)   // empty ground
        #expect(c.selection == .none)
    }

    @Test("right-click orders the selected unit: move on open ground, attack on an enemy tile")
    func rightClickOrders() {
        var c = InputController(mapWidth: 64)
        c.leftClick(tileX: 0, tileY: 0, hit: .unit(slot: 22))
        c.rightClick(tileX: 18, tileY: 16, enemyTarget: false, harvester: false)
        #expect(c.drainCommands() == [.move(unit: 22, tile: 16 * 64 + 18)])
        c.rightClick(tileX: 20, tileY: 16, enemyTarget: true, harvester: false)
        #expect(c.drainCommands() == [.attack(unit: 22, tile: 16 * 64 + 20)])
        // Draining clears the queue.
        #expect(c.drainCommands().isEmpty)
    }

    @Test("right-click with a harvester selected harvests (its default action), even over open ground or an enemy")
    func rightClickHarvester() {
        var c = InputController(mapWidth: 64)
        c.leftClick(tileX: 0, tileY: 0, hit: .unit(slot: 7))
        c.rightClick(tileX: 18, tileY: 16, enemyTarget: false, harvester: true)
        #expect(c.drainCommands() == [.harvest(unit: 7, tile: 16 * 64 + 18)])
        // Harvester wins over the enemy flag (a harvester can't attack).
        c.rightClick(tileX: 20, tileY: 16, enemyTarget: true, harvester: true)
        #expect(c.drainCommands() == [.harvest(unit: 7, tile: 16 * 64 + 20)])
    }

    @Test("right-click with no unit selected (or a structure) issues nothing")
    func rightClickNoUnit() {
        var c = InputController()
        c.rightClick(tileX: 5, tileY: 5, enemyTarget: false, harvester: false)
        #expect(c.drainCommands().isEmpty)
        c.leftClick(tileX: 1, tileY: 1, hit: .structure(slot: 4))
        c.rightClick(tileX: 5, tileY: 5, enemyTarget: true, harvester: false)
        #expect(c.drainCommands().isEmpty)   // a structure can't be ordered
    }

    @Test("an inspector-armed order makes the next left-click its target, then disarms")
    func pendingOrder() {
        var c = InputController(mapWidth: 64)
        c.leftClick(tileX: 0, tileY: 0, hit: .unit(slot: 7))
        c.beginOrder(.attack)
        #expect(c.pendingOrder == .attack)
        c.leftClick(tileX: 10, tileY: 12, hit: .unit(slot: 99))   // the target tile, not a re-selection
        #expect(c.drainCommands() == [.attack(unit: 7, tile: 12 * 64 + 10)])
        #expect(c.pendingOrder == nil)
        #expect(c.selection == .unit(slot: 7))   // selection unchanged by the targeting click
    }

    @Test("harvest/retreat orders arm + target like attack/move (the h/r shortcuts)")
    func harvestRetreatOrders() {
        var c = InputController(mapWidth: 64)
        c.leftClick(tileX: 0, tileY: 0, hit: .unit(slot: 7))
        c.beginOrder(.harvest)
        #expect(c.pendingOrder == .harvest)
        c.leftClick(tileX: 3, tileY: 4, hit: .none)
        #expect(c.drainCommands() == [.harvest(unit: 7, tile: 4 * 64 + 3)])
        c.beginOrder(.retreat)
        c.leftClick(tileX: 5, tileY: 6, hit: .none)
        #expect(c.drainCommands() == [.retreat(unit: 7, tile: 6 * 64 + 5)])
    }

    @Test("beginOrder is a no-op without a selected unit; stop + deselect")
    func armingGuardsAndStop() {
        var c = InputController()
        c.beginOrder(.move)
        #expect(c.pendingOrder == nil)            // nothing selected → not armed
        c.leftClick(tileX: 0, tileY: 0, hit: .unit(slot: 5))
        #expect(c.selectedUnits == [5])           // a single unit-click forms a one-unit group
        c.stopSelected()
        #expect(c.drainCommands() == [.stop(unit: 5)])
        c.beginOrder(.move)
        c.deselect()
        #expect(c.selection == .none && c.selectedUnits.isEmpty && c.pendingOrder == nil)
    }

    @Test("selectGroup selects a unit group; single-unit and structure clicks reset it")
    func groupSelection() {
        var c = InputController()
        c.selectGroup([3, 7, 12])
        #expect(c.selectedUnits == [3, 7, 12])
        #expect(c.selection == .unit(slot: 3))    // inspector mirrors the first
        c.leftClick(tileX: 1, tileY: 1, hit: .unit(slot: 9))   // a single click collapses the group
        #expect(c.selectedUnits == [9])
        c.leftClick(tileX: 2, tileY: 2, hit: .structure(slot: 4))   // selecting a building clears it
        #expect(c.selectedUnits.isEmpty)
        c.selectGroup([])                         // an empty box deselects
        #expect(c.selection == .none && c.selectedUnits.isEmpty)
    }

    @Test("a group order (right-click + armed) is issued to every selected unit")
    func groupOrders() {
        var c = InputController(mapWidth: 64)
        c.selectGroup([3, 7])
        c.rightClick(tileX: 10, tileY: 10, enemyTarget: false, harvester: false)
        let moveTile: UInt16 = 10 * 64 + 10
        let moves = c.drainCommands()
        #expect(moves == [Command.move(unit: 3, tile: moveTile), Command.move(unit: 7, tile: moveTile)])
        // An armed attack on the group → an attack command per unit.
        c.beginOrder(.attack)
        #expect(c.pendingOrder == .attack)
        c.leftClick(tileX: 5, tileY: 5, hit: .none)
        let attackTile: UInt16 = 5 * 64 + 5
        let attacks = c.drainCommands()
        #expect(attacks == [Command.attack(unit: 3, tile: attackTile), Command.attack(unit: 7, tile: attackTile)])
        // Stop hits the whole group.
        c.stopSelected()
        let stops = c.drainCommands()
        #expect(stops == [Command.stop(unit: 3), Command.stop(unit: 7)])
    }
}
