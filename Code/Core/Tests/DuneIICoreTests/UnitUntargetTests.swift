import Foundation
import Testing
@testable import DuneIICore

/// Tests for `Simulation.Units.untargetUnit` — port of OpenDUNE's
/// `Unit_UntargetMe` (`src/unit.c:1611`). Sweeps every other unit's
/// `targetMove` / `targetAttack` and clears any encoded reference to
/// the unit being freed. Called right before `UnitPool.free` in the
/// kill path (`Script_Unit_Die`) so no stale encoded index survives
/// in the pool.
@Suite("Units.untargetUnit — pool-wide reference sweep before free")
struct UnitUntargetTests {

    private static let trike: UInt8 = 13
    private static let trooper: UInt8 = 4

    /// Three-unit pool: victim at 36 (the unit being freed), two
    /// attackers at 30 + 31 each targeting victim via targetMove +
    /// targetAttack.
    private static func makeHost(victimIdx: Int = 36) -> Scripting.Host {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: victimIdx, type: trooper, houseID: 2)
        _ = pool.allocate(at: 30, type: trike, houseID: 1)
        _ = pool.allocate(at: 31, type: trike, houseID: 1)
        let encoded = Scripting.EncodedIndex.unit(UInt16(victimIdx)).raw
        var a = pool[30]; a.targetMove = encoded; a.targetAttack = encoded; pool[30] = a
        var b = pool[31]; b.targetMove = encoded; b.targetAttack = encoded; pool[31] = b
        return Scripting.Host(units: pool)
    }

    @Test("untargetUnit clears targetMove + targetAttack on every other unit that referenced the victim")
    func clearsBothFields() {
        let host = Self.makeHost()
        Simulation.Units.untargetUnit(poolIndex: 36, host: host)
        #expect(host.units[30].targetMove == 0)
        #expect(host.units[30].targetAttack == 0)
        #expect(host.units[31].targetMove == 0)
        #expect(host.units[31].targetAttack == 0)
    }

    @Test("untargetUnit leaves unrelated targets alone")
    func leavesUnrelatedTargetsAlone() {
        let host = Self.makeHost()
        // Attacker 31 targets a different unit (index 5, encoded).
        let otherEncoded = Scripting.EncodedIndex.unit(5).raw
        var b = host.units[31]
        b.targetMove = otherEncoded
        b.targetAttack = otherEncoded
        host.units[31] = b

        Simulation.Units.untargetUnit(poolIndex: 36, host: host)
        // Unit 30 still referenced the victim → cleared.
        #expect(host.units[30].targetMove == 0)
        #expect(host.units[30].targetAttack == 0)
        // Unit 31's targets point at a different unit → untouched.
        #expect(host.units[31].targetMove == otherEncoded)
        #expect(host.units[31].targetAttack == otherEncoded)
    }

    @Test("untargetUnit is a no-op for out-of-range pool indices")
    func outOfRangeIsNoOp() {
        let host = Self.makeHost()
        Simulation.Units.untargetUnit(poolIndex: -1, host: host)
        Simulation.Units.untargetUnit(poolIndex: 1_000_000, host: host)
        let encoded = Scripting.EncodedIndex.unit(36).raw
        #expect(host.units[30].targetMove == encoded)
        #expect(host.units[31].targetAttack == encoded)
    }

    @Test("untargetUnit doesn't clear references on freed (isUsed=false) slots")
    func skipsFreedSlots() {
        let host = Self.makeHost()
        host.units.free(at: 31)  // freed slots shouldn't be written to
        Simulation.Units.untargetUnit(poolIndex: 36, host: host)
        // Unit 30 is live → cleared.
        #expect(host.units[30].targetMove == 0)
        // Unit 31 was freed → stays in its post-free state (isUsed=false).
        #expect(host.units[31].isUsed == false)
    }

    @Test("untargetUnit doesn't encode with the wrong IT_UNIT kind")
    func doesNotMatchStructureEncoding() {
        let host = Self.makeHost()
        // Attacker 31's targets encode a STRUCTURE with index 36 —
        // different kind byte. Must not be cleared by a unit sweep.
        let structEncoded = Scripting.EncodedIndex.structure(36).raw
        var b = host.units[31]
        b.targetMove = structEncoded
        b.targetAttack = structEncoded
        host.units[31] = b

        Simulation.Units.untargetUnit(poolIndex: 36, host: host)
        #expect(host.units[31].targetMove == structEncoded)
        #expect(host.units[31].targetAttack == structEncoded)
    }
}
