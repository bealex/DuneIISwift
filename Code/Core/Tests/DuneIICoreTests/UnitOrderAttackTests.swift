import Foundation
import Testing
@testable import DuneIICore

/// Tests for `Simulation.Units.orderAttack` — the pure-sim side of the
/// right-click-attack slice. Mirrors OpenDUNE's `Unit_SetAction(ACTION_ATTACK)`
/// + `Unit_SetTarget` tail (`src/unit.c:497, 1131`):
/// - Always: `targetAttack = encoded(IT_UNIT, targetIndex)`,
///   `actionID = 0`, `currentDestination{X,Y} = 0` (so the scheduler reloads
///   the engine at the ATTACK entry-point next tick).
/// - Non-turret attacker: also `targetMove = targetAttack` + `route[0] = 0xFF`
///   so the chassis drives toward the target. Turreted units stay put and
///   rotate.
@Suite("Units.orderAttack — player attack-order bridge")
struct UnitOrderAttackTests {

    private static let trike: UInt8 = 13   // hasTurret = false
    private static let tank: UInt8 = 9     // hasTurret = true

    /// Two-unit pool: attacker on slot 0 (Atreides), target on slot 1
    /// (Harkonnen). Both wheeled trikes by default.
    private static func makePool(
        attackerType: UInt8 = trike,
        targetType: UInt8 = trike
    ) -> Simulation.UnitPool {
        var pool = Simulation.UnitPool()
        _ = pool.allocate(at: 0, type: attackerType, houseID: Simulation.House.atreides)
        _ = pool.allocate(at: 1, type: targetType, houseID: Simulation.House.harkonnen)
        var a = pool[0]
        a.positionX = 10 * 256 + 128
        a.positionY = 10 * 256 + 128
        pool[0] = a
        var t = pool[1]
        t.positionX = 20 * 256 + 128
        t.positionY = 20 * 256 + 128
        pool[1] = t
        return pool
    }

    // MARK: Happy path — non-turret (trike) attacker

    @Test("orderAttack on non-turret attacker writes targetAttack + targetMove + clears route")
    func nonTurretAttackerSetsBoth() {
        var units = Self.makePool()
        var attacker = units[0]
        attacker.actionID = Simulation.ActionID.guard_  // 3
        attacker.route[0] = 2  // stale route step
        attacker.currentDestinationX = 1234
        attacker.currentDestinationY = 5678
        attacker.targetAttack = 0
        attacker.targetMove = 0
        units[0] = attacker

        let ok = Simulation.Units.orderAttack(
            poolIndex: 0, targetUnitIndex: 1, units: &units
        )
        #expect(ok)

        let expected = Scripting.EncodedIndex.unit(1).raw
        #expect(units[0].targetAttack == expected)
        #expect(units[0].actionID == Simulation.ActionID.attack)
        #expect(units[0].targetMove == expected)        // non-turret → chase
        #expect(units[0].route[0] == 0xFF)
        #expect(units[0].currentDestinationX == 0)
        #expect(units[0].currentDestinationY == 0)
    }

    // MARK: Happy path — turret (tank) attacker

    @Test("orderAttack on turreted attacker leaves targetMove + route untouched")
    func turretAttackerLeavesMoveAlone() {
        var units = Self.makePool(attackerType: Self.tank)
        var attacker = units[0]
        attacker.targetMove = 0xABCD            // pre-existing, must survive
        attacker.route[0] = 4                   // pre-existing, must survive
        attacker.currentDestinationX = 1234
        attacker.currentDestinationY = 5678
        units[0] = attacker

        let ok = Simulation.Units.orderAttack(
            poolIndex: 0, targetUnitIndex: 1, units: &units
        )
        #expect(ok)

        let expected = Scripting.EncodedIndex.unit(1).raw
        #expect(units[0].targetAttack == expected)
        #expect(units[0].actionID == Simulation.ActionID.attack)
        #expect(units[0].targetMove == 0xABCD)  // untouched
        #expect(units[0].route[0] == 4)         // untouched
        // currentDestination still cleared so the scheduler reloads at
        // the ATTACK entry-point next tick (matches OpenDUNE
        // Unit_SetAction switchType=0 → 1 fall-through).
        #expect(units[0].currentDestinationX == 0)
        #expect(units[0].currentDestinationY == 0)
    }

    // MARK: Rejection paths (must not mutate pool)

    @Test("orderAttack on unallocated attacker returns false, pool unchanged")
    func rejectsUnallocatedAttacker() {
        var units = Simulation.UnitPool()
        _ = units.allocate(at: 1, type: Self.trike, houseID: Simulation.House.harkonnen)
        let before = units
        let ok = Simulation.Units.orderAttack(
            poolIndex: 0, targetUnitIndex: 1, units: &units
        )
        #expect(!ok)
        #expect(units == before)
    }

    @Test("orderAttack on unallocated target returns false, pool unchanged")
    func rejectsUnallocatedTarget() {
        var units = Simulation.UnitPool()
        _ = units.allocate(at: 0, type: Self.trike, houseID: Simulation.House.atreides)
        let before = units
        let ok = Simulation.Units.orderAttack(
            poolIndex: 0, targetUnitIndex: 1, units: &units
        )
        #expect(!ok)
        #expect(units == before)
    }

    @Test("orderAttack on freed attacker returns false")
    func rejectsFreedAttacker() {
        var units = Self.makePool()
        units.free(at: 0)
        let before = units
        let ok = Simulation.Units.orderAttack(
            poolIndex: 0, targetUnitIndex: 1, units: &units
        )
        #expect(!ok)
        #expect(units == before)
    }

    @Test("orderAttack on freed target returns false")
    func rejectsFreedTarget() {
        var units = Self.makePool()
        units.free(at: 1)
        let before = units
        let ok = Simulation.Units.orderAttack(
            poolIndex: 0, targetUnitIndex: 1, units: &units
        )
        #expect(!ok)
        #expect(units == before)
    }

    @Test("orderAttack on self returns false")
    func rejectsSelfAttack() {
        var units = Self.makePool()
        let before = units
        let ok = Simulation.Units.orderAttack(
            poolIndex: 0, targetUnitIndex: 0, units: &units
        )
        #expect(!ok)
        #expect(units == before)
    }

    @Test("orderAttack rejects out-of-range pool indices")
    func rejectsOutOfRange() {
        var units = Self.makePool()
        let before = units
        _ = Simulation.Units.orderAttack(poolIndex: -1, targetUnitIndex: 1, units: &units)
        _ = Simulation.Units.orderAttack(poolIndex: 200, targetUnitIndex: 1, units: &units)
        _ = Simulation.Units.orderAttack(poolIndex: 0, targetUnitIndex: -1, units: &units)
        _ = Simulation.Units.orderAttack(poolIndex: 0, targetUnitIndex: 200, units: &units)
        #expect(units == before)
    }

    // MARK: Semantic quirks

    // MARK: Attack enemy structure

    @Test("orderAttackStructure on non-turret trike flips action=attack + move-to-target")
    func orderAttackStructureNonTurret() {
        var units = Self.makePool()
        var structs = Simulation.StructurePool()
        _ = structs.allocate(at: 5, type: 12 /* REFINERY */, houseID: Simulation.House.harkonnen)
        var s = structs[5]
        s.positionX = 20 * 256
        s.positionY = 20 * 256
        structs[5] = s

        let ok = Simulation.Units.orderAttackStructure(
            poolIndex: 0, targetStructureIndex: 5,
            units: &units, structures: structs
        )
        #expect(ok)
        let u = units[0]
        #expect(u.actionID == Simulation.ActionID.attack)
        let encoded = Scripting.EncodedIndex.structure(5).raw
        #expect(u.targetAttack == encoded)
        // Non-turret attackers also drive to the target.
        #expect(u.targetMove == encoded)
        #expect(u.route[0] == 0xFF)
    }

    @Test("orderAttackStructure on turreted tank leaves move state untouched")
    func orderAttackStructureTurret() {
        var units = Self.makePool(attackerType: Self.tank)
        var u0 = units[0]
        u0.targetMove = 0xBEEF
        u0.route[0] = 3
        units[0] = u0
        var structs = Simulation.StructurePool()
        _ = structs.allocate(at: 5, type: 12, houseID: Simulation.House.harkonnen)
        var s = structs[5]
        s.positionX = 0
        s.positionY = 0
        structs[5] = s

        _ = Simulation.Units.orderAttackStructure(
            poolIndex: 0, targetStructureIndex: 5,
            units: &units, structures: structs
        )
        let u = units[0]
        // Turreted unit keeps its prior move state — rotates in place.
        #expect(u.targetMove == 0xBEEF)
        #expect(u.route[0] == 3)
        #expect(u.targetAttack == Scripting.EncodedIndex.structure(5).raw)
    }

    @Test("orderAttackStructure rejects unallocated target")
    func orderAttackStructureRejectsUnallocated() {
        var units = Self.makePool()
        let structs = Simulation.StructurePool()    // empty
        let before = units
        let ok = Simulation.Units.orderAttackStructure(
            poolIndex: 0, targetStructureIndex: 5,
            units: &units, structures: structs
        )
        #expect(!ok)
        #expect(units == before)
    }

    @Test("orderAttack overwrites a previous attack target")
    func overwritesPreviousTarget() {
        var units = Self.makePool()
        // Add a third unit (Harkonnen) at slot 2.
        _ = units.allocate(at: 2, type: Self.trike, houseID: Simulation.House.harkonnen)
        var u2 = units[2]
        u2.positionX = 30 * 256 + 128
        u2.positionY = 30 * 256 + 128
        units[2] = u2

        // First order: attack slot 1.
        _ = Simulation.Units.orderAttack(poolIndex: 0, targetUnitIndex: 1, units: &units)
        #expect(units[0].targetAttack == Scripting.EncodedIndex.unit(1).raw)

        // Re-target to slot 2.
        _ = Simulation.Units.orderAttack(poolIndex: 0, targetUnitIndex: 2, units: &units)
        #expect(units[0].targetAttack == Scripting.EncodedIndex.unit(2).raw)
    }
}
