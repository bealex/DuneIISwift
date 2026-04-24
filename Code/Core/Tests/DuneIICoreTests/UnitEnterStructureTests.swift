import Foundation
import Testing
@testable import DuneIICore

/// Tests for `Simulation.Units.enterStructure` — port of OpenDUNE's
/// `Unit_EnterStructure` hostile-entry path (`src/unit.c:2226..2265`).
/// When a ground unit arrives on a structure tile owned by a
/// different house, the structure takes
/// `min(unit.hp * 2, structure.hp / 2)` damage and the unit is
/// consumed.
///
/// Closes the SAVE007 tick-622 parity drift where SOLDIER u37 walks
/// onto the player CYARD for a 40 hp hit.
@Suite("Units.enterStructure — hostile ground-unit arrival on a structure tile")
struct UnitEnterStructureTests {

    private static let SOLDIER: UInt8 = 4
    private static let CYARD: UInt8 = 8  // STRUCTURE_CONSTRUCTION_YARD

    private static func makeHost(attackerHP: UInt16 = 20, defenderHP: UInt16 = 400) -> Scripting.Host {
        var units = Simulation.UnitPool()
        units.allocate(at: 37, type: SOLDIER, houseID: 2) // enemy
        var u = units[37]
        u.positionX = 30 * 256 + 128
        u.positionY = 25 * 256 + 128
        u.hitpoints = UInt16(attackerHP)
        units[37] = u

        var structures = Simulation.StructurePool()
        structures.allocate(at: 0, type: CYARD, houseID: 1) // Atreides (player)
        var s = structures[0]
        s.positionX = 30 * 256
        s.positionY = 25 * 256
        s.hitpoints = defenderHP
        s.hitpointsMax = 400
        structures[0] = s

        return Scripting.Host(units: units, structures: structures)
    }

    @Test("enterStructure applies min(unit.hp * 2, structure.hp / 2) damage and removes the attacker")
    func appliesDamageAndRemoves() {
        let host = Self.makeHost(attackerHP: 20, defenderHP: 400)
        // Baseline: min(20*2=40, 400/2=200) → 40 damage.
        let consumed = Simulation.Units.enterStructure(
            poolIndex: 37, structureIndex: 0, host: host
        )
        #expect(consumed == true)
        #expect(host.units[37].isUsed == false, "attacker consumed")
        #expect(host.structures[0].hitpoints == 360, "CYARD 400 → 360 (40 damage)")
    }

    @Test("enterStructure uses structure.hp/2 when unit has higher hp*2")
    func damageCappedByStructureHalfHP() {
        // Unit hp=128 → 256. Structure hp=200, half=100. min = 100.
        let host = Self.makeHost(attackerHP: 128, defenderHP: 200)
        _ = Simulation.Units.enterStructure(
            poolIndex: 37, structureIndex: 0, host: host
        )
        #expect(host.structures[0].hitpoints == 100, "structure.hp/2 cap applied")
        #expect(host.units[37].isUsed == false)
    }

    @Test("enterStructure is a no-op when attacker and defender share a houseID (allied entry)")
    func alliedEntryIsNoOp() {
        let host = Self.makeHost()
        // Flip the unit's house to match the structure's.
        var u = host.units[37]
        u.houseID = host.structures[0].houseID
        host.units[37] = u

        let consumed = Simulation.Units.enterStructure(
            poolIndex: 37, structureIndex: 0, host: host
        )
        #expect(consumed == false, "allied entry must not consume the unit")
        #expect(host.units[37].isUsed == true, "attacker still alive")
        #expect(host.structures[0].hitpoints == 400, "no damage on allied entry")
    }

    @Test("enterStructure clears any other unit's targetMove pointing at the freed attacker")
    func untargetsAttackerOnConsume() {
        let host = Self.makeHost()
        // Add a third unit targeting the attacker (u37).
        host.units.allocate(at: 30, type: Self.SOLDIER, houseID: 1) // Atreides tank
        var t = host.units[30]
        let encoded37 = Scripting.EncodedIndex.unit(37).raw
        t.targetMove = encoded37
        t.targetAttack = encoded37
        host.units[30] = t

        _ = Simulation.Units.enterStructure(
            poolIndex: 37, structureIndex: 0, host: host
        )
        #expect(host.units[30].targetMove == 0,
                "untargetUnit must clear other units' stale targetMove")
        #expect(host.units[30].targetAttack == 0,
                "untargetUnit must clear other units' stale targetAttack")
    }

    @Test("enterStructure rejects invalid pool indices")
    func rejectsInvalidIndices() {
        let host = Self.makeHost()
        #expect(Simulation.Units.enterStructure(
            poolIndex: -1, structureIndex: 0, host: host) == false)
        #expect(Simulation.Units.enterStructure(
            poolIndex: 37, structureIndex: 1_000_000, host: host) == false)
        #expect(host.structures[0].hitpoints == 400)
        #expect(host.units[37].isUsed == true)
    }

    /// Scheduler-level integration: a SOLDIER walking onto a hostile
    /// CYARD via `tickMovement` (route step, not direct
    /// `enterStructure` call) must trigger the damage + consume
    /// path. Guards against regressions in the wiring between
    /// `Scheduler.tickMovement`'s arrival block and the new
    /// `Simulation.Units.enterStructure` helper.
    @Test("Scheduler.tickMovement triggers enterStructure when a ground unit arrives on a hostile structure tile")
    func schedulerArrivalTriggersEnterStructure() {
        let host = Self.makeHost()
        // Position the SOLDIER one tile SW of the CYARD (CYARD at
        // anchor (30, 25) covers tiles (30..31, 25..26)). Target
        // a specific tile inside the footprint via `currentDest`.
        var u = host.units[37]
        u.positionX = 29 * 256 + 128
        u.positionY = 26 * 256 + 128
        u.currentDestinationX = UInt16(30 * 256 + 128)
        u.currentDestinationY = UInt16(26 * 256 + 128)
        u.orientationCurrent = 64   // E
        u.orientationTarget = 64
        u.orientationSpeed = 0
        u.movingSpeed = 255
        u.speed = 15
        u.speedPerTick = 255
        u.speedRemainder = 255
        u.actionID = Simulation.ActionID.hunt
        u.distanceToDestination = 300   // large so first step isn't treated as arrival
        host.units[37] = u

        // Minimal scheduler seed so the movement pass fires.
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(
            program: program,
            functions: [Scripting.VM.Function?](repeating: nil, count: 64)
        )
        var scheduler = Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm)
        scheduler.perTickCadenceGatesEnabled = true
        scheduler.perUnitInterleavedTickOrder = true

        // Tick until the SOLDIER arrives; cap at 20 ticks so a
        // regression can't hang the test forever.
        var consumed = false
        for _ in 0..<20 {
            scheduler.tick()
            if !host.units[37].isUsed {
                consumed = true
                break
            }
        }
        #expect(consumed == true,
                "SOLDIER should be consumed after stepping onto CYARD tile")
        #expect(host.structures[0].hitpoints < 400,
                "CYARD must take damage on arrival")
    }
}
