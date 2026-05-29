import Testing
import DuneIIContracts
import DuneIIWorld
@testable import DuneIISimulation

// Note: no `import Foundation` — it would bring `Foundation.Unit` (the `Measurement` base class) into
// scope and make the bare `Unit` type annotations below ambiguous. This file needs only the engine.

/// Decision-trace coverage for the occupant + structure branches of `Unit_GetTileEnterScore` and for
/// `Unit_IsValidMovementIntoStructure` — the paths the no-objects golden map can't reach. Each asserts
/// the transcribed OpenDUNE branch (`unit.c:660`, `unit.c:2335`).
@Suite("Unit movement-into-tile decision trace")
struct UnitMovementDecisionTests {
    let unitPrim: any UnitPrimitives = DefaultUnitPrimitives()
    let mapPrim: any MapPrimitives = DefaultMapPrimitives()
    let housePrim: any HousePrimitives = DefaultHousePrimitives()
    let validTile: UInt16 = 20 * 64 + 20   // x=20,y=20: inside the scale-0 playable rect

    /// A bare allocated-looking unit (so `indexEncode` yields a non-zero encoded index).
    func makeUnit(index: Int, type: UnitType, house: HouseID, targetMove: UInt16 = 0) -> Unit {
        var u = Unit()
        u.o.index = UInt16(index)
        u.o.type = UInt8(type.rawValue)
        u.o.houseID = UInt8(house.rawValue)
        u.o.flags = [.used, .allocated, .isUnit]
        u.targetMove = targetMove
        return u
    }

    func makeStructure(index: Int, type: StructureType, house: HouseID, linkedID: UInt8 = 0xFF) -> Structure {
        var s = Structure()
        s.o.index = UInt16(index)
        s.o.type = UInt8(type.rawValue)
        s.o.houseID = UInt8(house.rawValue)
        s.o.linkedID = linkedID
        s.o.flags = [.used, .allocated]
        return s
    }

    func placeUnit(_ state: inout GameState, _ u: Unit, at packed: UInt16) {
        state.units[Int(u.o.index)] = u
        state.map[Int(packed)].hasUnit = true
        state.map[Int(packed)].index = UInt8(Int(u.o.index) + 1)
    }

    /// Register a unit in the pool (allocated) without putting it on the map — so `indexEncode` yields
    /// its real encoded index, as it does for any moving unit in OpenDUNE.
    func registerUnit(_ state: inout GameState, _ u: Unit) {
        state.units[Int(u.o.index)] = u
    }

    func placeStructure(_ state: inout GameState, _ s: Structure, at packed: UInt16) {
        state.structures[Int(s.o.index)] = s
        state.map[Int(packed)].hasStructure = true
        state.map[Int(packed)].index = UInt8(Int(s.o.index) + 1)
    }

    func score(_ state: GameState, _ mover: Unit, _ packed: UInt16, orient8: UInt16 = 0) -> Int16 {
        unitPrim.tileEnterScore(mover, packed: packed, orient8: orient8, in: state,
                                map: mapPrim, house: housePrim)
    }

    // MARK: tileEnterScore occupant branches

    @Test("allied occupant blocks the tile (256)")
    func alliedOccupant() {
        var state = GameState()
        let occupant = makeUnit(index: 5, type: .soldier, house: .harkonnen)
        placeUnit(&state, occupant, at: validTile)
        let mover = makeUnit(index: 1, type: .tank, house: .harkonnen)  // same house ⇒ allied
        #expect(score(state, mover, validTile) == 256)
    }

    @Test("enemy non-foot occupant blocks the tile (256)")
    func enemyVehicleOccupant() {
        var state = GameState()
        placeUnit(&state, makeUnit(index: 5, type: .tank, house: .ordos), at: validTile)
        let mover = makeUnit(index: 1, type: .tank, house: .harkonnen)
        #expect(score(state, mover, validTile) == 256)   // occupant not on foot ⇒ uncrushable
    }

    @Test("non-tracked mover can't crush an enemy foot occupant (256)")
    func footMoverCannotCrush() {
        var state = GameState()
        placeUnit(&state, makeUnit(index: 5, type: .soldier, house: .ordos), at: validTile)
        let mover = makeUnit(index: 1, type: .soldier, house: .harkonnen)  // foot, not tracked/harvester
        #expect(score(state, mover, validTile) == 256)
    }

    @Test("saboteur targeting the occupant scores 0")
    func saboteurTargetsOccupant() {
        var state = GameState()
        let occupant = makeUnit(index: 5, type: .soldier, house: .ordos)
        placeUnit(&state, occupant, at: validTile)
        let enc = state.indexEncode(occupant.o.index, type: .unit)
        let mover = makeUnit(index: 1, type: .saboteur, house: .harkonnen, targetMove: enc)
        #expect(score(state, mover, validTile) == 0)
    }

    // MARK: tileEnterScore structure branch

    @Test("accessible structure scores -res; inaccessible scores 256")
    func structureBranch() {
        let tank = makeUnit(index: 1, type: .tank, house: .harkonnen)
        var state = GameState()
        registerUnit(&state, tank)
        // Same owner, repair facility accepts a tank (enterFilter bit 9), not linked ⇒ res 1 ⇒ -1.
        placeStructure(&state, makeStructure(index: 3, type: .repair, house: .harkonnen), at: validTile)
        #expect(score(state, tank, validTile) == -1)

        // Refinery's enterFilter (harvester only) rejects the tank ⇒ res 0 ⇒ 256.
        var state2 = GameState()
        registerUnit(&state2, tank)
        placeStructure(&state2, makeStructure(index: 4, type: .refinery, house: .harkonnen), at: validTile)
        #expect(score(state2, tank, validTile) == 256)
    }

    // MARK: isValidMovementIntoStructure

    @Test("other owner: saboteur targeting always enters (2)")
    func otherOwnerSaboteur() {
        let state = GameState()
        let s = makeStructure(index: 3, type: .lightVehicle, house: .ordos)
        let enc = state.indexEncode(s.o.index, type: .structure)
        let sab = makeUnit(index: 1, type: .saboteur, house: .harkonnen, targetMove: enc)
        #expect(unitPrim.isValidMovementIntoStructure(sab, s, in: state) == 2)
    }

    @Test("other owner: foot unit into conquerable — enter if targeted (2), else move close (1)")
    func otherOwnerFootConquerable() {
        let state = GameState()
        let s = makeStructure(index: 3, type: .lightVehicle, house: .ordos)  // factory + conquerable
        let enc = state.indexEncode(s.o.index, type: .structure)
        let targeting = makeUnit(index: 1, type: .soldier, house: .harkonnen, targetMove: enc)
        let passing = makeUnit(index: 1, type: .soldier, house: .harkonnen, targetMove: 0)
        #expect(unitPrim.isValidMovementIntoStructure(targeting, s, in: state) == 2)
        #expect(unitPrim.isValidMovementIntoStructure(passing, s, in: state) == 1)
    }

    @Test("other owner: non-foot unit cannot enter (0)")
    func otherOwnerVehicle() {
        let state = GameState()
        let s = makeStructure(index: 3, type: .lightVehicle, house: .ordos)
        let tank = makeUnit(index: 1, type: .tank, house: .harkonnen)
        #expect(unitPrim.isValidMovementIntoStructure(tank, s, in: state) == 0)
    }

    @Test("same owner: enterFilter gates the unit type")
    func sameOwnerEnterFilter() {
        let tank = makeUnit(index: 1, type: .tank, house: .harkonnen)
        var state = GameState()
        registerUnit(&state, tank)
        // Repair accepts a tank (bit 9), not linked ⇒ 1; linked ⇒ 0.
        let repair = makeStructure(index: 3, type: .repair, house: .harkonnen)
        #expect(unitPrim.isValidMovementIntoStructure(tank, repair, in: state) == 1)
        let repairLinked = makeStructure(index: 3, type: .repair, house: .harkonnen, linkedID: 7)
        #expect(unitPrim.isValidMovementIntoStructure(tank, repairLinked, in: state) == 0)
        // Refinery (harvester only) rejects the tank ⇒ 0.
        let refinery = makeStructure(index: 4, type: .refinery, house: .harkonnen)
        #expect(unitPrim.isValidMovementIntoStructure(tank, refinery, in: state) == 0)
    }

    @Test("same owner: structure script variable 4 linking the unit enters (2)")
    func sameOwnerScriptVar4() {
        let tank = makeUnit(index: 1, type: .tank, house: .harkonnen)
        var state = GameState()
        registerUnit(&state, tank)
        var repair = makeStructure(index: 3, type: .repair, house: .harkonnen)
        repair.o.script.variables[4] = state.indexEncode(tank.o.index, type: .unit)
        #expect(unitPrim.isValidMovementIntoStructure(tank, repair, in: state) == 2)
    }
}
