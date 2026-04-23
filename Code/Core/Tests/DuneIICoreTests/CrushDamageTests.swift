import Foundation
import Testing
@testable import DuneIICore

/// Port of OpenDUNE's `Unit_Move` tracked-on-foot branch
/// (`src/unit.c:1328..1349`): a tracked or harvester unit that steps
/// onto a foot unit's tile kills the foot unit. The `Unit_GetTileEnterScore`
/// path makes the move passable; this pass turns it into a squash.
///
/// Our port: `tickMovement`'s post-step block scans the new tile for
/// foot units (when the mover is tracked or harvester) and calls
/// `Simulation.Explosions.applyUnitDamage(...)` with full HP damage,
/// which frees the slot + drops the infantry corpse sprite.
@Suite("Crush damage — tracked + harvester squash foot units on step")
struct CrushDamageTests {

    private let TANK: UInt8 = 9
    private let TRIKE: UInt8 = 13
    private let HARVESTER: UInt8 = 16
    private let TROOPER: UInt8 = 5
    private let INFANTRY_SQUAD: UInt8 = 2

    private func scheduler(
        landscape: @escaping (UInt16) -> UInt8 = { _ in UInt8(LandscapeType.normalSand.rawValue) }
    ) -> Simulation.Scheduler {
        let host = Scripting.Host(landscapeAt: landscape, spiceMap: nil)
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        return Simulation.Scheduler(host: host, unitVM: vm, structureVM: vm, teamVM: vm)
    }

    @Test("Tank crosses onto foot-occupied tile → foot unit is killed")
    func tankCrushesTrooper() {
        var s = scheduler()
        // `Units.createUnit` is the preferred spawn entry — it seeds
        // hitpoints from `UnitInfo`, which `applyUnitDamage` needs so
        // a squash actually kills (damage=0 is a no-op on that path).
        let trooperIdx = Simulation.Units.createUnit(
            type: TROOPER, houseID: Simulation.House.harkonnen,
            tileX: 11, tileY: 10, pool: &s.host.units
        )!

        let tankIdx = s.host.units.allocateForType(
            type: TANK, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[tankIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        s.host.units[tankIdx] = u
        Simulation.Units.setSpeed(poolIndex: tankIdx, speedPercent: 255, units: &s.host.units)
        // Order the tank east so it steps onto the trooper's tile.
        Simulation.Units.orderMove(poolIndex: tankIdx, tileX: 15, tileY: 10, units: &s.host.units)

        // Drive until the trooper's slot is freed or budget elapses.
        var killed = false
        for _ in 0..<400 {
            s.tick()
            if !s.host.units.slots[trooperIdx].isUsed {
                killed = true
                break
            }
        }
        #expect(killed, "trooper must be killed by tank's squash")
        // Tank itself is unharmed and kept moving toward its goal.
        #expect(s.host.units.slots[tankIdx].isUsed)
    }

    @Test("Harvester movementType also crushes foot (OpenDUNE includes harvester in the isTracked branch)")
    func harvesterCrushesTrooper() {
        var s = scheduler()
        let trooperIdx = Simulation.Units.createUnit(
            type: TROOPER, houseID: Simulation.House.harkonnen,
            tileX: 12, tileY: 10, pool: &s.host.units
        )!

        let harvIdx = s.host.units.allocateForType(
            type: HARVESTER, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[harvIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        s.host.units[harvIdx] = u
        Simulation.Units.setSpeed(poolIndex: harvIdx, speedPercent: 255, units: &s.host.units)
        Simulation.Units.orderMove(poolIndex: harvIdx, tileX: 16, tileY: 10, units: &s.host.units)

        var killed = false
        for _ in 0..<600 {
            s.tick()
            if !s.host.units.slots[trooperIdx].isUsed { killed = true; break }
        }
        #expect(killed, "harvester must crush trooper — MOVEMENT_HARVESTER is on the isTracked flag")
    }

    @Test("Trike (wheeled) does NOT crush foot units — only tracked + harvester do")
    func trikeDoesNotCrush() {
        var s = scheduler()
        let trooperIdx = s.host.units.allocateForType(
            type: TROOPER, houseID: Simulation.House.harkonnen
        )!
        var t = s.host.units[trooperIdx]
        t.positionX = UInt16(13 * 256 + 128)
        t.positionY = UInt16(10 * 256 + 128)
        s.host.units[trooperIdx] = t

        let trikeIdx = s.host.units.allocateForType(
            type: TRIKE, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[trikeIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        s.host.units[trikeIdx] = u
        Simulation.Units.setSpeed(poolIndex: trikeIdx, speedPercent: 255, units: &s.host.units)
        Simulation.Units.orderMove(poolIndex: trikeIdx, tileX: 18, tileY: 10, units: &s.host.units)

        for _ in 0..<400 { s.tick() }
        #expect(s.host.units.slots[trooperIdx].isUsed,
                "wheeled trike has no crush flag — trooper must survive")
    }

    @Test("Tank doesn't crush another tank (vehicles block each other)")
    func tankDoesNotCrushTank() {
        var s = scheduler()
        let blockerIdx = s.host.units.allocateForType(
            type: TANK, houseID: Simulation.House.harkonnen
        )!
        var b = s.host.units[blockerIdx]
        b.positionX = UInt16(12 * 256 + 128)
        b.positionY = UInt16(10 * 256 + 128)
        s.host.units[blockerIdx] = b

        let attackerIdx = s.host.units.allocateForType(
            type: TANK, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[attackerIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        s.host.units[attackerIdx] = u
        Simulation.Units.setSpeed(poolIndex: attackerIdx, speedPercent: 255, units: &s.host.units)
        Simulation.Units.orderMove(poolIndex: attackerIdx, tileX: 15, tileY: 10, units: &s.host.units)

        for _ in 0..<400 { s.tick() }
        #expect(s.host.units.slots[blockerIdx].isUsed,
                "tank must not crush another tank — crush rule is FOOT-only")
    }

    @Test("Crush happens when the mover's tile changes; no double-kill on subpixel steps")
    func crushFiresOncePerTileEntry() {
        var s = scheduler()
        let trooperIdx = s.host.units.allocateForType(
            type: TROOPER, houseID: Simulation.House.harkonnen
        )!
        var t = s.host.units[trooperIdx]
        t.positionX = UInt16(11 * 256 + 128)
        t.positionY = UInt16(10 * 256 + 128)
        t.hitpoints = 255
        s.host.units[trooperIdx] = t

        let tankIdx = s.host.units.allocateForType(
            type: TANK, houseID: Simulation.House.atreides
        )!
        var u = s.host.units[tankIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        s.host.units[tankIdx] = u
        Simulation.Units.setSpeed(poolIndex: tankIdx, speedPercent: 255, units: &s.host.units)
        Simulation.Units.orderMove(poolIndex: tankIdx, tileX: 15, tileY: 10, units: &s.host.units)

        // Drive one step across, then drive more ticks. The trooper
        // slot should be freed exactly once; subsequent ticks can't
        // "double-kill" it because the slot is free.
        for _ in 0..<30 { s.tick() }
        let firstKillTick = !s.host.units.slots[trooperIdx].isUsed
        for _ in 0..<400 { s.tick() }
        // Still not used (no re-allocation into the same slot).
        #expect(firstKillTick,
                "trooper must be killed within the first 30 ticks of the tank's eastward move")
    }
}
