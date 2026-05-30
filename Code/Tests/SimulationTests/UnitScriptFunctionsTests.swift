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

    @Test("getInfo returns each unit info field")
    func getInfo() {
        var (s, slot) = stateWithUnit(.tank, house: 0, at: 20 * 64 + 20)
        let ui = UnitInfo[.tank]
        s.units[slot].o.hitpoints = ui.o.hitpoints / 2
        s.units[slot].orientation[0].current = 50
        s.units[slot].orientation[0].target = 60
        s.units[slot].orientation[1].current = 70
        s.units[slot].orientation[1].target = 85
        s.units[slot].targetAttack = 0x4002
        s.units[slot].movingSpeed = 9
        s.units[slot].o.seenByHouses = 0b1   // seen by player (house 0)

        #expect(fns.getInfo(slot: slot, field: 0x00, in: &s)
                == UInt16(UInt32(ui.o.hitpoints / 2) * 256 / UInt32(ui.o.hitpoints)))
        #expect(fns.getInfo(slot: slot, field: 0x02, in: &s) == ui.fireDistance << 8)
        #expect(fns.getInfo(slot: slot, field: 0x03, in: &s) == s.units[slot].o.index)
        #expect(fns.getInfo(slot: slot, field: 0x04, in: &s) == 50)
        #expect(fns.getInfo(slot: slot, field: 0x05, in: &s) == 0x4002)
        #expect(fns.getInfo(slot: slot, field: 0x06, in: &s) == s.indexEncode(20 * 64 + 20, type: .tile))
        #expect(fns.getInfo(slot: slot, field: 0x07, in: &s) == UInt16(ut(.tank)))
        #expect(fns.getInfo(slot: slot, field: 0x08, in: &s) == s.indexEncode(s.units[slot].o.index, type: .unit))
        #expect(fns.getInfo(slot: slot, field: 0x09, in: &s) == 9)
        #expect(fns.getInfo(slot: slot, field: 0x0A, in: &s) == 10)   // |60 - 50|
        #expect(fns.getInfo(slot: slot, field: 0x0B, in: &s) == 0)    // no destination
        #expect(fns.getInfo(slot: slot, field: 0x0C, in: &s) == 1)    // fireDelay 0
        #expect(fns.getInfo(slot: slot, field: 0x0D, in: &s) == (ui.flags.contains(.explodeOnDeath) ? 1 : 0))
        #expect(fns.getInfo(slot: slot, field: 0x0E, in: &s) == 0)    // house 0
        #expect(fns.getInfo(slot: slot, field: 0x10, in: &s) == 70)   // turret current (tank has turret)
        #expect(fns.getInfo(slot: slot, field: 0x11, in: &s) == 15)   // |85 - 70|
        #expect(fns.getInfo(slot: slot, field: 0x12, in: &s) == 0)    // always 0 in 1.07
        #expect(fns.getInfo(slot: slot, field: 0x13, in: &s) == 1)    // seen by player
        #expect(fns.getInfo(slot: slot, field: 0xFF, in: &s) == 0)    // unknown field

        // targetMove validity, destination, byScenario, deviation.
        #expect(fns.getInfo(slot: slot, field: 0x01, in: &s) == 0)    // targetMove 0 = invalid
        let tm = s.indexEncode(s.units[slot].o.index, type: .unit)
        s.units[slot].targetMove = tm
        #expect(fns.getInfo(slot: slot, field: 0x01, in: &s) == tm)
        s.units[slot].currentDestination = Tile32.unpack(30 * 64 + 30)
        #expect(fns.getInfo(slot: slot, field: 0x0B, in: &s) == 1)
        #expect(fns.getInfo(slot: slot, field: 0x0F, in: &s) == 0)
        s.units[slot].o.flags.insert(.byScenario)
        #expect(fns.getInfo(slot: slot, field: 0x0F, in: &s) == 1)
        s.units[slot].deviated = 1
        #expect(fns.getInfo(slot: slot, field: 0x0E, in: &s) == 2)    // deviated ⇒ Ordos
    }

    @Test("findClosestRefinery: harvester prefers nearest busy, else nearest; non-harvester stamps tile")
    func findClosestRefinery() {
        var (s, harv) = stateWithUnit(.harvester, house: 0, at: 10 * 64 + 10)

        // Two house-0 refineries: a near busy one, a far idle one.
        let near = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.refinery.rawValue))!
        s.structures[near].o.houseID = 0
        s.structures[near].o.position = Tile32.unpack(12 * 64 + 12)
        s.structures[near].state = .busy
        let far = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.refinery.rawValue))!
        s.structures[far].o.houseID = 0
        s.structures[far].o.position = Tile32.unpack(40 * 64 + 40)
        s.structures[far].state = .idle

        #expect(s.unitFindClosestRefinery(harv) == 0)   // had no origin
        #expect(s.units[harv].originEncoded == s.indexEncode(s.structures[near].o.index, type: .structure))

        // No busy refinery ⇒ falls back to the nearest of any state (still `near`).
        s.structures[near].state = .idle
        s.units[harv].originEncoded = 0
        _ = s.unitFindClosestRefinery(harv)
        #expect(s.units[harv].originEncoded == s.indexEncode(s.structures[near].o.index, type: .structure))

        // A non-harvester just stamps its current tile as the origin.
        let (s2, tank) = stateWithUnit(.tank, house: 0, at: 5 * 64 + 5)
        var st2 = s2
        #expect(st2.unitFindClosestRefinery(tank) == 0)
        #expect(st2.units[tank].originEncoded == st2.indexEncode(5 * 64 + 5, type: .tile))
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

    @Test("setDestination native: 0/invalid clears targetMove; a tile sets it; harvester refinery special")
    func setDestination() {
        // encoded 0 ⇒ clear targetMove, return 0.
        var (s, slot) = stateWithUnit(.tank)
        s.units[slot].targetMove = 1234
        #expect(fns.setDestination(slot: slot, encoded: 0, in: &s) == 0)
        #expect(s.units[slot].targetMove == 0)

        // A (vacant) tile index ⇒ the Unit_SetDestination primitive sets targetMove + route[0]=0xFF.
        var (s2, slot2) = stateWithUnit(.tank, at: 20 * 64 + 20)
        let tile = s2.indexEncode(40 * 64 + 40, type: .tile)
        #expect(fns.setDestination(slot: slot2, encoded: tile, in: &s2) == 0)
        #expect(s2.units[slot2].targetMove == tile)
        #expect(s2.units[slot2].route[0] == 0xFF)

        // Harvester targeting a tile (no structure there) ⇒ raw store + route reset (the special branch).
        var (s3, harv) = stateWithUnit(.harvester, at: 10 * 64 + 10)
        let tile3 = s3.indexEncode(12 * 64 + 12, type: .tile)
        s3.units[harv].route[0] = 3
        #expect(fns.setDestination(slot: harv, encoded: tile3, in: &s3) == 0)
        #expect(s3.units[harv].targetMove == tile3)
        #expect(s3.units[harv].route[0] == 0xFF)
    }

    @Test("findStructure: first idle, unlinked, unbusied structure of the unit's house + type, else 0")
    func findStructure() {
        var (s, slot) = stateWithUnit(.tank, house: 0)
        let type = UInt16(StructureType.refinery.rawValue)
        func addRefinery(house: UInt8) -> Int {
            let i = s.structureAllocate(index: Pool.structureIndexInvalid,
                                        type: UInt8(StructureType.refinery.rawValue))!
            s.structures[i].o.houseID = house
            s.structures[i].state = .idle
            return i
        }

        #expect(fns.findStructure(slot: slot, type: type, in: s) == 0)   // none

        // A busy one is skipped; a wrong-house one is skipped; a wrong-type one is skipped.
        let busy = addRefinery(house: 0); s.structures[busy].state = .busy
        let enemy = addRefinery(house: 2)
        #expect(fns.findStructure(slot: slot, type: type, in: s) == 0)

        // An idle, unlinked, unbusied house-0 refinery matches.
        let good = addRefinery(house: 0)
        #expect(fns.findStructure(slot: slot, type: type, in: s)
                == s.indexEncode(s.structures[good].o.index, type: .structure))

        // Link it ⇒ skipped again (back to none).
        s.structures[good].o.script.variables[4] = 99
        #expect(fns.findStructure(slot: slot, type: type, in: s) == 0)
        _ = enemy
    }

    @Test("idleAction: ground unit twitches (LCG roll + a turret/body rotation on a low roll); air no-ops")
    func idleAction() {
        // A tracked tank on a fresh LCG (seed 0 ⇒ Tools_RandomLCG_Range(0,10)=0 ≤ 2 ⇒ it rotates). Predict
        // the exact draws (1 LCG, then level-select + orientation) via a probe with the same RNG state.
        var (s, slot) = stateWithUnit(.tank)
        var probe = s
        let roll = probe.randomLCG.range(0, 10)
        #expect(roll <= 2)
        let level = (probe.random256.next() & 1) == 0 ? 1 : 0
        let orientation = Int8(truncatingIfNeeded: probe.random256.next())

        #expect(fns.idleAction(slot: slot, in: &s) == 0)
        #expect(s.units[slot].orientation[level].target == orientation)
        #expect(s.units[slot].orientation[level].speed != 0)               // it is now rotating
        #expect(s.units[slot].orientation[1 - level].target == 0)          // the other level untouched
        // The RNG advanced by exactly the predicted draws — the streams stay in lockstep.
        #expect(s.random256.next() == probe.random256.next())

        // An air unit (winger) no-ops after a single LCG roll — no orientation change, random256 untouched.
        var (sa, air) = stateWithUnit(.carryall)
        var probeA = sa
        _ = probeA.randomLCG.range(0, 10)
        #expect(fns.idleAction(slot: air, in: &sa) == 0)
        #expect(sa.units[air].orientation[0].target == 0)
        #expect(sa.units[air].orientation[1].target == 0)
        #expect(sa.random256.next() == probeA.random256.next())           // no random256 draw happened
    }
}
