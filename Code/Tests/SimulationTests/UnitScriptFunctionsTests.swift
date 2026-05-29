import Testing
import DuneIIContracts
import DuneIIWorld
@testable import DuneIISimulation

/// Per-function coverage for the `Script_Unit_*` natives (`UnitScriptFunctions`), checked against the
/// OpenDUNE logic in `src/script/unit.c`. The mutating ones go through `DefaultUnitPrimitives`, so
/// results are cross-checked against direct primitive calls; the tile pieces reuse the golden
/// `Tile_GetDirection` / `Tile_MoveByRandom`.
@Suite("Script_Unit_* natives")
struct UnitScriptFunctionsTests {
    let fns = UnitScriptFunctions()
    private func ut(_ t: UnitType) -> UInt8 { UInt8(t.rawValue) }

    /// A GameState (house 0, player 0) with one unit of `type` at `packed`. Returns the state + slot.
    private func stateWithUnit(_ type: UnitType, house: UInt8 = 0,
                               at packed: UInt16 = 20 * 64 + 20) -> (GameState, Int) {
        var s = GameState()
        s.playerHouseID = 0
        _ = s.houseAllocate(index: 0)
        _ = s.houseAllocate(index: 2)
        s.houses[0].unitCountMax = 100
        s.houses[2].unitCountMax = 100
        let slot = s.unitAllocate(index: 0, type: ut(type), houseID: house)!
        s.units[slot].o.position = Tile32.unpack(packed)
        return (s, slot)
    }

    @Test("getAmount: own amount, or the linked unit's")
    func getAmount() {
        var (s, slot) = stateWithUnit(.tank)
        s.units[slot].amount = 7
        #expect(fns.getAmount(s.units[slot], in: s) == 7)

        let linked = s.unitAllocate(index: 0, type: ut(.harvester), houseID: 0)!
        s.units[linked].amount = 12
        s.units[slot].o.linkedID = UInt8(linked)
        #expect(fns.getAmount(s.units[slot], in: s) == 12)
    }

    @Test("getOrientation: direction to a tile, else own base orientation")
    func getOrientation() {
        var (s, slot) = stateWithUnit(.tank, at: 20 * 64 + 20)
        s.units[slot].orientation[0].current = 33
        let targetEnc = s.indexEncode(40 * 64 + 40, type: .tile)
        let expected = UInt16(bitPattern: Int16(Tile32.direction(from: s.units[slot].o.position,
                                                                 to: s.indexGetTile(targetEnc))))
        #expect(fns.getOrientation(s.units[slot], encoded: targetEnc, in: s) == expected)
        #expect(fns.getOrientation(s.units[slot], encoded: 0, in: s) == 33)   // invalid ⇒ own orientation
    }

    @Test("setSpeed: scaled by 192/256 unless scenario-placed")
    func setSpeed() {
        // Not scenario-placed ⇒ 200 → 150.
        var (s, slot) = stateWithUnit(.tank)
        var ref = s.units[slot]
        DefaultUnitPrimitives().setSpeed(&ref, speed: 150, gameSpeed: s.gameSpeed)
        let r = fns.setSpeed(slot: slot, requestedSpeed: 200, in: &s)
        #expect(r == UInt16(ref.speed))
        #expect(s.units[slot].speed == ref.speed)

        // Scenario-placed ⇒ no scaling (100 stays 100).
        var (s2, slot2) = stateWithUnit(.tank)
        s2.units[slot2].o.flags.insert(.byScenario)
        var ref2 = s2.units[slot2]
        DefaultUnitPrimitives().setSpeed(&ref2, speed: 100, gameSpeed: s2.gameSpeed)
        _ = fns.setSpeed(slot: slot2, requestedSpeed: 100, in: &s2)
        #expect(s2.units[slot2].speed == ref2.speed)
    }

    @Test("setOrientation aims the body at the requested orientation")
    func setOrientation() {
        var (s, slot) = stateWithUnit(.tank)
        let ret = fns.setOrientation(slot: slot, orientation: 64, in: &s)
        #expect(s.units[slot].orientation[0].target == 64)
        #expect(ret == 0)   // non-instant: current is unchanged this tick
    }

    @Test("rotate: starts turning the turret toward the attack target; 0 when nothing to do")
    func rotate() {
        var (s, slot) = stateWithUnit(.tank, at: 20 * 64 + 20)   // tank has a turret
        // No target ⇒ 0.
        #expect(fns.rotate(slot: slot, in: &s) == 0)

        // A valid target in a different direction ⇒ starts rotating turret (level 1), returns 1.
        s.units[slot].targetAttack = s.indexEncode(40 * 64 + 40, type: .tile)
        let expectDir = Tile32.direction(from: s.units[slot].o.position, to: s.indexGetTile(s.units[slot].targetAttack))
        #expect(fns.rotate(slot: slot, in: &s) == 1)
        #expect(s.units[slot].orientation[1].target == expectDir)

        // Busy moving (has a destination) ⇒ 1 without changing anything.
        var (s2, slot2) = stateWithUnit(.tank)
        s2.units[slot2].currentDestination = Tile32.unpack(30 * 64 + 30)
        #expect(fns.rotate(slot: slot2, in: &s2) == 1)
    }

    @Test("stop halts the unit")
    func stop() {
        var (s, slot) = stateWithUnit(.tank)
        s.units[slot].speed = 3
        #expect(fns.stop(slot: slot, in: &s) == 0)
        #expect(s.units[slot].speed == 0)
    }

    @Test("isInTransport reflects the flag")
    func isInTransport() {
        var (s, slot) = stateWithUnit(.tank)
        #expect(fns.isInTransport(s.units[slot]) == 0)
        s.units[slot].o.flags.insert(.inTransport)
        #expect(fns.isInTransport(s.units[slot]) == 1)
    }

    @Test("getRandomTile: a seeded random tile, but only for a tile-typed argument")
    func getRandomTile() {
        var (s, slot) = stateWithUnit(.tank)
        // Non-tile argument ⇒ 0 (and no RNG draw).
        let unitEnc = s.indexEncode(UInt16(slot), type: .unit)
        #expect(fns.getRandomTile(slot: slot, encoded: unitEnc, in: &s) == 0)

        var probe = s   // value copy → same RNG state
        let expectTile = Tile32.moveByRandom(s.units[slot].o.position, distance: 80, center: true,
                                             rng: &probe.random256)
        let expected = probe.indexEncode(expectTile.packed, type: .tile)
        let tileArg = s.indexEncode(0, type: .tile)
        #expect(fns.getRandomTile(slot: slot, encoded: tileArg, in: &s) == expected)
    }

    @Test("setTarget: aims at a valid target; turretless also moves; clearing zeroes it")
    func setTarget() {
        // Tank has a turret: sets targetAttack + aims the turret, leaves targetMove alone.
        var (s, slot) = stateWithUnit(.tank, at: 20 * 64 + 20)
        let target = s.indexEncode(40 * 64 + 40, type: .tile)
        #expect(fns.setTarget(slot: slot, target: target, in: &s) == target)
        #expect(s.units[slot].targetAttack == target)
        #expect(s.units[slot].targetMove == 0)

        // Turretless (soldier): also sets targetMove.
        var (s2, slot2) = stateWithUnit(.soldier, at: 20 * 64 + 20)
        #expect(fns.setTarget(slot: slot2, target: target, in: &s2) == target)
        #expect(s2.units[slot2].targetMove == target)

        // Clear.
        #expect(fns.setTarget(slot: slot, target: 0, in: &s) == 0)
        #expect(s.units[slot].targetAttack == 0)
    }

    @Test("setDestinationDirect sets the destination and aims at it")
    func setDestinationDirect() {
        var (s, slot) = stateWithUnit(.tank, at: 20 * 64 + 20)
        let dest = s.indexEncode(40 * 64 + 40, type: .tile)
        #expect(fns.setDestinationDirect(slot: slot, encoded: dest, in: &s) == 0)
        #expect(s.units[slot].currentDestination == s.indexGetTile(dest))
        let expectDir = Tile32.direction(from: s.units[slot].o.position, to: s.units[slot].currentDestination)
        #expect(s.units[slot].orientation[0].target == expectDir)

        #expect(fns.setDestinationDirect(slot: slot, encoded: 0, in: &s) == 0)   // invalid ⇒ no-op
    }
}
