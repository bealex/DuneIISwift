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
        c.leftClick(tileX: 0, tileY: 0, hit: .none)  // empty ground
        #expect(c.selection == .none)
    }

    @Test("right-click orders the selected unit: move on open ground, attack on an enemy tile")
    func rightClickOrders() {
        var c = InputController(mapWidth: 64)
        c.leftClick(tileX: 0, tileY: 0, hit: .unit(slot: 22))
        c.rightClick(tileX: 18, tileY: 16, enemyTarget: false, harvester: false)
        #expect(c.drainCommands() == [ .move(unit: 22, tile: 16 * 64 + 18) ])
        c.rightClick(tileX: 20, tileY: 16, enemyTarget: true, harvester: false)
        #expect(c.drainCommands() == [ .attack(unit: 22, tile: 16 * 64 + 20) ])
        // Draining clears the queue.
        #expect(c.drainCommands().isEmpty)
    }

    @Test("right-click with a harvester selected harvests (its default action), even over open ground or an enemy")
    func rightClickHarvester() {
        var c = InputController(mapWidth: 64)
        c.leftClick(tileX: 0, tileY: 0, hit: .unit(slot: 7))
        c.rightClick(tileX: 18, tileY: 16, enemyTarget: false, harvester: true)
        #expect(c.drainCommands() == [ .harvest(unit: 7, tile: 16 * 64 + 18) ])
        // Harvester wins over the enemy flag (a harvester can't attack).
        c.rightClick(tileX: 20, tileY: 16, enemyTarget: true, harvester: true)
        #expect(c.drainCommands() == [ .harvest(unit: 7, tile: 16 * 64 + 20) ])
    }

    @Test("right-click with no unit selected (or a structure) issues nothing")
    func rightClickNoUnit() {
        var c = InputController()
        c.rightClick(tileX: 5, tileY: 5, enemyTarget: false, harvester: false)
        #expect(c.drainCommands().isEmpty)
        c.leftClick(tileX: 1, tileY: 1, hit: .structure(slot: 4))
        c.rightClick(tileX: 5, tileY: 5, enemyTarget: true, harvester: false)
        #expect(c.drainCommands().isEmpty)  // a structure can't be ordered
    }

    @Test("an inspector-armed order makes the next left-click its target, then disarms")
    func pendingOrder() {
        var c = InputController(mapWidth: 64)
        c.leftClick(tileX: 0, tileY: 0, hit: .unit(slot: 7))
        c.beginOrder(.attack)
        #expect(c.pendingOrder == .attack)
        c.leftClick(tileX: 10, tileY: 12, hit: .unit(slot: 99))  // the target tile, not a re-selection
        #expect(c.drainCommands() == [ .attack(unit: 7, tile: 12 * 64 + 10) ])
        #expect(c.pendingOrder == nil)
        #expect(c.selection == .unit(slot: 7))  // selection unchanged by the targeting click
    }

    @Test("harvest/retreat orders arm + target like attack/move (the h/r shortcuts)")
    func harvestRetreatOrders() {
        var c = InputController(mapWidth: 64)
        c.leftClick(tileX: 0, tileY: 0, hit: .unit(slot: 7))
        c.beginOrder(.harvest)
        #expect(c.pendingOrder == .harvest)
        c.leftClick(tileX: 3, tileY: 4, hit: .none)
        #expect(c.drainCommands() == [ .harvest(unit: 7, tile: 4 * 64 + 3) ])
        c.beginOrder(.retreat)
        c.leftClick(tileX: 5, tileY: 6, hit: .none)
        #expect(c.drainCommands() == [ .retreat(unit: 7, tile: 6 * 64 + 5) ])
    }

    @Test("beginOrder is a no-op without a selected unit; stop + deselect")
    func armingGuardsAndStop() {
        var c = InputController()
        c.beginOrder(.move)
        #expect(c.pendingOrder == nil)  // nothing selected → not armed
        c.leftClick(tileX: 0, tileY: 0, hit: .unit(slot: 5))
        #expect(c.selectedUnits == [ 5 ])  // a single unit-click forms a one-unit group
        c.stopSelected()
        #expect(c.drainCommands() == [ .stop(unit: 5) ])
        c.beginOrder(.move)
        c.deselect()
        #expect(c.selection == .none && c.selectedUnits.isEmpty && c.pendingOrder == nil)
    }

    @Test("selectGroup selects a unit group; single-unit and structure clicks reset it")
    func groupSelection() {
        var c = InputController()
        c.selectGroup([ 3, 7, 12 ])
        #expect(c.selectedUnits == [ 3, 7, 12 ])
        #expect(c.selection == .unit(slot: 3))  // inspector mirrors the first
        c.leftClick(tileX: 1, tileY: 1, hit: .unit(slot: 9))  // a single click collapses the group
        #expect(c.selectedUnits == [ 9 ])
        c.leftClick(tileX: 2, tileY: 2, hit: .structure(slot: 4))  // selecting a building clears it
        #expect(c.selectedUnits.isEmpty)
        c.selectGroup([])  // an empty box deselects
        #expect(c.selection == .none && c.selectedUnits.isEmpty)
    }

    @Test("dominantGroup keeps only the most-numerous unit type (ties → lowest type id)")
    func dominantGroup() {
        // slots 0,1,2 are type 5 (×3); slot 3 is type 9 (×1) → keep the three type-5 slots.
        let types: [Int: Int] = [ 0: 5, 1: 5, 2: 5, 3: 9 ]
        #expect(InputController.dominantGroup([ 0, 1, 2, 3 ], typeOf: { types[$0]! }) == [ 0, 1, 2 ])
        // tie 2-vs-2 between type 5 and type 9 → the lower id (5) wins.
        let tie: [Int: Int] = [ 0: 9, 1: 9, 2: 5, 3: 5 ]
        #expect(InputController.dominantGroup([ 0, 1, 2, 3 ], typeOf: { tie[$0]! }) == [ 2, 3 ])
        #expect(InputController.dominantGroup([], typeOf: { _ in 0 }).isEmpty)
    }

    @Test("clusterGroup grows the connected same-type cluster by ≤radius hops (a whole row, not just near the click)")
    func clusterGroup() {
        // A row of five units one tile apart at x = 0,2,4,6,8 (all y = 0). With radius 3 every neighbour is a
        // hop away, so clicking the leftmost (slot 0) reaches the whole row via chained hops — even slot 4 at
        // x = 8, which is 8 tiles (> 3) from the click point itself.
        let row: [(slot: Int, x: Int, y: Int)] = [
            (0, 0, 0), (1, 2, 0), (2, 4, 0), (3, 6, 0), (4, 8, 0),
        ]
        #expect(InputController.clusterGroup(row, clicked: 0, radius: 3) == [ 0, 1, 2, 3, 4 ])
        // A gap wider than the radius splits the cluster: slot 9 at x = 20 is unreachable from the row.
        let split = row + [ (9, 20, 0) ]
        #expect(InputController.clusterGroup(split, clicked: 0, radius: 3) == [ 0, 1, 2, 3, 4 ])
        #expect(InputController.clusterGroup(split, clicked: 9, radius: 3) == [ 9 ])
        // The clicked slot absent ⇒ empty (host falls back to a single select).
        #expect(InputController.clusterGroup(row, clicked: 7, radius: 3).isEmpty)
        #expect(InputController.clusterGroup([], clicked: 0, radius: 3).isEmpty)
    }

    @Test("a move keeps the group's formation (offset per unit); attack targets the exact tile; edges clamp")
    func formationMove() {
        var c = InputController(mapWidth: 64, mapHeight: 64)
        // Two units offset (-1,0) and (+1,0) from the anchor. A move to (10,10) sends them to (9,10)/(11,10).
        c.selectGroup([ 3, 7 ], formation: [ 3: TileOffset(dx: -1, dy: 0), 7: TileOffset(dx: 1, dy: 0) ])
        c.rightClick(tileX: 10, tileY: 10, enemyTarget: false, harvester: false)
        let left: UInt16 = 10 * 64 + 9, right: UInt16 = 10 * 64 + 11
        #expect(c.drainCommands() == [ Command.move(unit: 3, tile: left), Command.move(unit: 7, tile: right) ])
        // Attack ignores formation — the whole group targets the one tile.
        c.beginOrder(.attack)
        c.leftClick(tileX: 5, tileY: 5, hit: .none)
        let at: UInt16 = 5 * 64 + 5
        #expect(c.drainCommands() == [ Command.attack(unit: 3, tile: at), Command.attack(unit: 7, tile: at) ])
        // Off-map offsets clamp into the map: a move to (0,0) keeps unit 3's −1 offset at column 0.
        c.rightClick(tileX: 0, tileY: 0, enemyTarget: false, harvester: false)
        #expect(c.drainCommands() == [ Command.move(unit: 3, tile: 0), Command.move(unit: 7, tile: 1) ])
        // A fresh single-unit click clears the formation (a later move targets the exact tile).
        c.leftClick(tileX: 0, tileY: 0, hit: .unit(slot: 3))
        #expect(c.formation.isEmpty)
    }

    @Test("a group order (right-click + armed) is issued to every selected unit")
    func groupOrders() {
        var c = InputController(mapWidth: 64)
        c.selectGroup([ 3, 7 ])
        c.rightClick(tileX: 10, tileY: 10, enemyTarget: false, harvester: false)
        let moveTile: UInt16 = 10 * 64 + 10
        let moves = c.drainCommands()
        #expect(moves == [ Command.move(unit: 3, tile: moveTile), Command.move(unit: 7, tile: moveTile) ])
        // An armed attack on the group → an attack command per unit.
        c.beginOrder(.attack)
        #expect(c.pendingOrder == .attack)
        c.leftClick(tileX: 5, tileY: 5, hit: .none)
        let attackTile: UInt16 = 5 * 64 + 5
        let attacks = c.drainCommands()
        #expect(attacks == [ Command.attack(unit: 3, tile: attackTile), Command.attack(unit: 7, tile: attackTile) ])
        // Stop hits the whole group.
        c.stopSelected()
        let stops = c.drainCommands()
        #expect(stops == [ Command.stop(unit: 3), Command.stop(unit: 7) ])
    }
}
