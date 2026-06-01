import Testing
import DuneIIContracts
import DuneIIWorld
@testable import DuneIISimulation

/// Coverage for the player-order (command) path (`UnitOrders`, OpenDUNE `gui/viewport.c` click→order +
/// `Unit_SetDestination`/`Unit_SetTarget`/`Unit_FindTargetAround`). A synthetic per-type `ScriptInfo`
/// lets `Unit_SetAction` load without a real `UNIT.EMC`.
@Suite("Unit orders (command pipeline)")
struct UnitOrdersTests {
    let orders = UnitOrders(scriptInfo: ScriptInfo(program: [UInt16](repeating: 0, count: 64),
                                                   offsets: (0 ..< 30).map { UInt16($0) }))
    private func u(_ t: UnitType) -> UInt8 { UInt8(t.rawValue) }

    private func makeState() -> GameState {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        _ = s.houseAllocate(index: 2)
        s.houses[0].unitCountMax = 100
        s.houses[2].unitCountMax = 100
        return s
    }

    @discardableResult
    private func place(_ s: inout GameState, _ t: UnitType, house: UInt8, packed: UInt16) -> Int {
        let slot = s.unitAllocate(index: Pool.unitIndexInvalid, type: u(t), houseID: house)!
        s.units[slot].o.position = Tile32.unpack(packed)
        s.map[Int(packed)].hasUnit = true
        s.map[Int(packed)].index = UInt8(slot + 1)
        return slot
    }

    @Test("move order to an empty tile sets the action + targetMove (tile)")
    func moveToEmpty() {
        var s = makeState()
        let slot = place(&s, .tank, house: 0, packed: 1300)
        orders.apply(.move(unit: UInt16(slot), tile: 2000), in: &s)
        #expect(s.units[slot].actionID == UInt8(ActionType.move.rawValue))
        #expect(s.units[slot].targetMove == s.indexEncode(2000, type: .tile))
        #expect(s.units[slot].route[0] == 0xFF)
        #expect(s.units[slot].targetAttack == 0)
    }

    @Test("move order onto a structure tile resolves targetMove to that structure")
    func moveOntoStructure() {
        var s = makeState()
        let slot = place(&s, .tank, house: 0, packed: 1300)
        let str = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.refinery.rawValue))!
        s.structures[str].o.houseID = 2
        s.map[2000].hasStructure = true
        s.map[2000].index = UInt8(str + 1)
        orders.apply(.move(unit: UInt16(slot), tile: 2000), in: &s)
        #expect(s.units[slot].targetMove == s.indexEncode(s.structures[str].o.index, type: .structure))
    }

    @Test("attack order snaps to the enemy on the tile; a turret unit doesn't also move")
    func attackEnemy() {
        var s = makeState()
        let mover = place(&s, .tank, house: 0, packed: 1300)     // tank has a turret
        let enemy = place(&s, .tank, house: 2, packed: 2000)
        orders.apply(.attack(unit: UInt16(mover), tile: 2000), in: &s)
        #expect(s.units[mover].actionID == UInt8(ActionType.attack.rawValue))
        #expect(s.units[mover].targetAttack == s.indexEncode(s.units[enemy].o.index, type: .unit))
        #expect(s.units[mover].targetMove == 0)   // turret unit aims, doesn't move
    }

    @Test("attack order from a turretless unit also sets targetMove")
    func attackTurretless() {
        var s = makeState()
        let mover = place(&s, .soldier, house: 0, packed: 1300)   // foot, no turret
        let enemy = place(&s, .tank, house: 2, packed: 2000)
        orders.apply(.attack(unit: UInt16(mover), tile: 2000), in: &s)
        let enc = s.indexEncode(s.units[enemy].o.index, type: .unit)
        #expect(s.units[mover].targetAttack == enc)
        #expect(s.units[mover].targetMove == enc)
    }

    @Test("stop order clears the unit's targets/route and sets it to GUARD")
    func stopOrder() {
        var s = makeState()
        let slot = place(&s, .tank, house: 0, packed: 1300)
        orders.apply(.move(unit: UInt16(slot), tile: 2000), in: &s)   // give it a move first
        #expect(s.units[slot].targetMove != 0)
        orders.apply(.stop(unit: UInt16(slot)), in: &s)
        #expect(s.units[slot].actionID == UInt8(ActionType.guard_.rawValue))
        #expect(s.units[slot].targetMove == 0)
        #expect(s.units[slot].targetAttack == 0)
        #expect(s.units[slot].route[0] == 0xFF)
    }

    @Test("harvest order sets the harvest action + targetMove to the tile")
    func harvestOrder() {
        var s = makeState()
        let slot = place(&s, .harvester, house: 0, packed: 1300)
        orders.apply(.harvest(unit: UInt16(slot), tile: 2000), in: &s)
        #expect(s.units[slot].actionID == UInt8(ActionType.harvest.rawValue))
        #expect(s.units[slot].targetMove == s.indexEncode(2000, type: .tile))
        #expect(s.units[slot].targetAttack == 0)
    }

    @Test("retreat order sets the retreat action + a target")
    func retreatOrder() {
        var s = makeState()
        let slot = place(&s, .tank, house: 0, packed: 1300)
        orders.apply(.retreat(unit: UInt16(slot), tile: 2000), in: &s)
        #expect(s.units[slot].actionID == UInt8(ActionType.retreat.rawValue))
        #expect(s.units[slot].targetAttack != 0)
    }

    @Test("setAction command clears targets/route and sets the chosen no-target action (e.g. Return)")
    func setActionOrder() {
        var s = makeState()
        let slot = place(&s, .harvester, house: 0, packed: 1300)
        orders.apply(.move(unit: UInt16(slot), tile: 2000), in: &s)   // give it a move first
        #expect(s.units[slot].targetMove != 0)
        orders.apply(.setAction(unit: UInt16(slot), action: UInt8(ActionType.return.rawValue)), in: &s)
        #expect(s.units[slot].actionID == UInt8(ActionType.return.rawValue))
        #expect(s.units[slot].targetMove == 0)
        #expect(s.units[slot].targetAttack == 0)
        #expect(s.units[slot].route[0] == 0xFF)
    }

    @Test("findTargetAround returns an adjacent unit's tile, else the tile itself")
    func findTargetAround() {
        var s = makeState()
        _ = place(&s, .tank, house: 2, packed: 2001)   // one tile east of 2000
        #expect(orders.findTargetAround(2000, in: s) == 2001)   // snaps to the adjacent unit
        #expect(orders.findTargetAround(3000, in: s) == 3000)   // nothing around ⇒ the tile itself
    }
}
