import DuneIIContracts
import Testing

@testable import DuneIISimulation
@testable import DuneIIWorld

/// The carryall transport natives: `MoveToStructure` (0x1E), `Pickup` (0x22), `TransportDeliver` (0x14).
@Suite("Carryall transport")
struct CarryallTests {
    private let info = ScriptInfo(program: [ UInt16 ](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func base() -> (GameState, UnitCombat) {
        var s = GameState()
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        return (s, UnitCombat(movement: UnitMovement(scriptInfo: info)))
    }

    private func addUnit(_ s: inout GameState, _ type: UnitType, at packed: UInt16) -> Int {
        let slot = s.unitAllocate(index: 0, type: UInt8(type.rawValue), houseID: 0)!
        s.units[slot].o.position = Tile32.unpack(packed)
        return slot
    }

    private func addStructure(_ s: inout GameState, _ type: StructureType, _ st: StructureState, at packed: UInt16)
        -> Int
    {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        s.structures[slot].o.houseID = 0
        s.structures[slot].state = st
        s.structures[slot].o.position = Tile32.unpack(packed)
        return slot
    }

    @Test("moveToStructure links the carrier to the nearest idle structure and heads there")
    func moveToStructure() {
        var (s, combat) = base()
        let carry = addUnit(&s, .carryall, at: Tile32.packXY(x: 20, y: 20))
        _ = addStructure(&s, .refinery, .idle, at: Tile32.packXY(x: 25, y: 20))
        let ret = combat.moveToStructure(slot: carry, type: UInt16(StructureType.refinery.rawValue), in: &s)
        #expect(ret != 0)
        #expect(s.units[carry].targetMove == ret)
        #expect(s.units[carry].o.script.variables[4] != 0)  // two-way var-4 link formed
    }

    @Test("pickup grabs the unit waiting under a READY structure and empties it")
    func pickupFromStructure() {
        var (s, combat) = base()
        let carry = addUnit(&s, .carryall, at: Tile32.packXY(x: 20, y: 20))
        let waiting = addUnit(&s, .trike, at: Tile32.packXY(x: 22, y: 20))
        let fac = addStructure(&s, .lightVehicle, .ready, at: Tile32.packXY(x: 22, y: 20))
        s.structures[fac].o.linkedID = UInt8(waiting)  // a unit waiting under it
        s.units[waiting].o.linkedID = 0xFF  // no chain
        s.units[carry].targetMove = s.indexEncode(s.structures[fac].o.index, type: .structure)

        let ret = combat.pickup(slot: carry, in: &s)
        #expect(ret == 1)
        #expect(s.units[carry].o.linkedID == UInt8(truncatingIfNeeded: Int(s.units[waiting].o.index)))
        #expect(s.units[carry].o.flags.contains(.inTransport))
        #expect(s.structures[fac].o.linkedID == 0xFF)  // structure emptied
        #expect(s.structures[fac].state == .idle)  // → idle
    }

    @Test("pickup is a no-op when the carrier already carries something")
    func pickupWhileCarrying() {
        var (s, combat) = base()
        let carry = addUnit(&s, .carryall, at: Tile32.packXY(x: 20, y: 20))
        s.units[carry].o.linkedID = 7  // already carrying
        #expect(combat.pickup(slot: carry, in: &s) == 0)
    }

    @Test("transportDeliver drops the cargo on the ground and unlinks the carrier")
    func deliverGround() {
        var (s, combat) = base()
        let carry = addUnit(&s, .carryall, at: Tile32.packXY(x: 20, y: 20))
        let cargo = addUnit(&s, .trike, at: Tile32.packXY(x: 0, y: 0))
        s.units[cargo].o.flags.insert(.isNotOnMap)  // riding inside
        s.units[carry].o.linkedID = UInt8(cargo)
        s.units[cargo].o.linkedID = 0xFF
        s.units[carry].o.flags.insert(.inTransport)
        s.units[carry].targetMove = s.indexEncode(Tile32.packXY(x: 20, y: 20), type: .tile)  // a ground tile

        let ret = combat.transportDeliver(slot: carry, in: &s)
        #expect(ret == 1)
        #expect(s.units[carry].o.linkedID == 0xFF)  // cargo released
        #expect(!s.units[carry].o.flags.contains(.inTransport))
        #expect(!s.units[cargo].o.flags.contains(.isNotOnMap))  // cargo placed on the map
    }

    @Test("a winger flies toward its currentDestination each movement tick (winger flight motion)")
    func wingerFlight() {
        var (s, _) = base()
        let move = UnitMovement(scriptInfo: info)
        let carry = addUnit(&s, .carryall, at: Tile32.packXY(x: 10, y: 20))
        s.units[carry].currentDestination = Tile32.unpack(Tile32.packXY(x: 40, y: 20))  // far east

        // Aim east + full winger cruise speed (Unit_CreateBullet/carryall script set 255).
        let dir = Tile32.direction(from: s.units[carry].o.position, to: s.units[carry].currentDestination)
        move.unit.setOrientation(&s.units[carry], orientation: dir, rotateInstantly: true, level: 0)
        move.unit.setSpeed(&s.units[carry], speed: 255, gameSpeed: s.gameSpeed)
        #expect(s.units[carry].speed != 0)

        let before = s.units[carry].o.position
        let flipBefore = s.units[carry].o.flags.contains(.animationFlip)
        var flips = 0
        for _ in 0 ..< 24 {
            let prev = s.units[carry].o.flags.contains(.animationFlip)
            move.movementTick(slot: carry, in: &s)
            if s.units[carry].o.flags.contains(.animationFlip) != prev { flips += 1 }
        }
        let after = s.units[carry].o.position

        // It actually flew (a winger steps along its orientation toward the destination, ignoring gameSpeed).
        #expect(after.x > before.x)
        #expect(
            Tile32.distance(from: after, to: s.units[carry].currentDestination)
                < Tile32.distance(from: before, to: s.units[carry].currentDestination)
        )
        // Each Unit_Move on a winger toggles animationFlip (the rotor/wing-beat render flag).
        #expect(flips > 0)
        _ = flipBefore
    }

    @Test("a winger advances in sub-tile steps, never snapping a whole tile at once (#1)")
    func wingerMovesSubTile() {
        var (s, _) = base()
        let move = UnitMovement(scriptInfo: info)
        let carry = addUnit(&s, .carryall, at: Tile32.packXY(x: 10, y: 20))
        s.units[carry].currentDestination = Tile32.unpack(Tile32.packXY(x: 50, y: 20))
        let dir = Tile32.direction(from: s.units[carry].o.position, to: s.units[carry].currentDestination)
        move.unit.setOrientation(&s.units[carry], orientation: dir, rotateInstantly: true, level: 0)
        move.unit.setSpeed(&s.units[carry], speed: 255, gameSpeed: s.gameSpeed)

        // Record the position after each movement tick over a long flight; the per-step delta must stay
        // within one tile (256 sub-units). A tile-by-tile teleport would be >= 256.
        var maxStep = 0
        var prev = Int(s.units[carry].o.position.x)
        var moved = false
        for _ in 0 ..< 120 {
            move.movementTick(slot: carry, in: &s)
            let now = Int(s.units[carry].o.position.x)
            let step = abs(now - prev)
            if step > 0 { moved = true }
            maxStep = max(maxStep, step)
            prev = now
        }
        #expect(moved)  // it actually flew
        #expect(maxStep < 256, "a movement tick jumped \(maxStep) sub-units (>= a full tile)")
    }

    @Test("a winger rotates the shortest way in BOTH directions (#2)")
    func wingerRotatesShortestPath() {
        var (s, _) = base()
        let move = UnitMovement(scriptInfo: info)
        let carry = addUnit(&s, .carryall, at: Tile32.packXY(x: 20, y: 20))

        // From North (0) to East (+64): current should climb 0 -> 64 (positive steps).
        s.units[carry].orientation[0].current = 0
        move.unit.setOrientation(&s.units[carry], orientation: 64, rotateInstantly: false, level: 0)
        #expect(s.units[carry].orientation[0].speed > 0)  // turning clockwise (increasing)
        var guardCount = 0
        while s.units[carry].orientation[0].speed != 0 && guardCount < 100 {
            move.unit.rotate(&s.units[carry], level: 0); guardCount += 1
        }
        #expect(s.units[carry].orientation[0].current == 64)

        // From North (0) to West (192 == -64): current should go the SHORT way (down through 255),
        // i.e. a negative turn — not the long way up. This is the "always one direction" check.
        s.units[carry].orientation[0].current = 0
        move.unit.setOrientation(&s.units[carry], orientation: -64, rotateInstantly: false, level: 0)
        #expect(s.units[carry].orientation[0].speed < 0)  // turning counter-clockwise
        move.unit.rotate(&s.units[carry], level: 0)
        #expect(s.units[carry].orientation[0].current < 0)  // stepped DOWN (toward 192/-64), not up
    }

    @Test("transportDeliver into an idle refinery hands the cargo over (Unit_EnterStructure)")
    func deliverToRefinery() {
        var (s, combat) = base()
        let carry = addUnit(&s, .carryall, at: Tile32.packXY(x: 20, y: 20))
        let cargo = addUnit(&s, .harvester, at: Tile32.packXY(x: 0, y: 0))
        s.units[cargo].o.flags.insert(.isNotOnMap)
        s.units[carry].o.linkedID = UInt8(cargo)
        s.units[cargo].o.linkedID = 0xFF
        s.units[carry].o.flags.insert(.inTransport)
        let refinery = addStructure(&s, .refinery, .idle, at: Tile32.packXY(x: 25, y: 20))
        s.structures[refinery].o.linkedID = 0xFF
        s.units[carry].targetMove = s.indexEncode(s.structures[refinery].o.index, type: .structure)

        let ret = combat.transportDeliver(slot: carry, in: &s)
        #expect(ret == 1)
        #expect(s.units[carry].o.linkedID == 0xFF)  // handed over
        #expect(!s.units[carry].o.flags.contains(.inTransport))
    }
}
