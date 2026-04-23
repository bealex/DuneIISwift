import Foundation
import Testing
@testable import DuneIICore

/// Slice 9: `Host.spiceLevelDidChange` fires on real transitions and
/// stays silent on clamps / no-ops. Exercises the scheduler's
/// `changeSpice` wrapper without any scene / renderer dependency.
@Suite("SpiceMap repaint callback — level transitions reach the host notifier")
struct SpiceRepaintTests {

    private func emptyScheduler(
        spiceMap: Simulation.SpiceMap,
        rng: @escaping () -> UInt8,
        onLevelChange: @escaping (UInt16, Simulation.SpiceMap.Level, Simulation.SpiceMap) -> Void
    ) -> Simulation.Scheduler {
        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            spiceMap: spiceMap,
            spiceLevelDidChange: onLevelChange
        )
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        return Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm, harvestRNG: rng
        )
    }

    /// Harvester on a thick spice tile. One tick triggers `apply(-1)`
    /// via `harvestSpiceStep` once the drain gate opens — we force
    /// the RNG so the gate always opens (rng=0 → gate passes).
    @Test("Harvester on thick spice drives exactly one thick→thin repaint")
    func thickToThinFiresOnce() {
        var map = Simulation.SpiceMap()
        // Seed tile (10,10) as thick.
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))   // bare → thin
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))   // thin → thick

        var fires: [(UInt16, Simulation.SpiceMap.Level)] = []
        var scheduler = emptyScheduler(
            spiceMap: map, rng: { 0 }
        ) { packed, level, _ in
            fires.append((packed, level))
        }

        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: 16 /* HARVESTER */, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 0
        u.inTransport = false
        scheduler.host.units[hIdx] = u

        scheduler.tickHarvesting()

        // thick → thin on the drained tile.
        #expect(fires.count == 1)
        #expect(fires.first?.0 == UInt16(10 * 64 + 10))
        #expect(fires.first?.1 == .thin)
    }

    /// Harvester standing on a BARE tile — apply is a no-op, no fires.
    @Test("No callback when apply is a no-op (bare tile drain)")
    func bareDrainNoFire() {
        var map = Simulation.SpiceMap()
        // Seed tile (10,10) bare (sand via init with a closure → .bare).
        // No manual seeding needed — default `init()` gives all .notSand,
        // which is silent for apply(-1). We need a sandy-but-bare tile
        // to exercise the no-op path; synthesize by init with closure:
        map = Simulation.SpiceMap { _ in .normalSand }
        let packed = UInt16(10 * 64 + 10)
        #expect(map[packed] == .bare)

        var fires: [(UInt16, Simulation.SpiceMap.Level)] = []
        var scheduler = emptyScheduler(
            spiceMap: map, rng: { 0 }
        ) { packed, level, _ in
            fires.append((packed, level))
        }
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: 16, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128); u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 0
        scheduler.host.units[hIdx] = u
        scheduler.tickHarvesting()

        #expect(fires.isEmpty)
    }

    /// Host with no `spiceLevelDidChange` closure — apply still runs
    /// and the scheduler doesn't crash.
    @Test("Nil notifier leaves existing drain flow intact")
    func nilNotifierSafe() {
        var map = Simulation.SpiceMap()
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))
        _ = map.apply(delta: +1, at: UInt16(10 * 64 + 10))
        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            spiceMap: map,
            spiceLevelDidChange: nil
        )
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        var scheduler = Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm,
            harvestRNG: { 0 }
        )
        let hIdx = scheduler.host.units.allocate(
            in: 16...19, type: 16, houseID: Simulation.House.atreides
        )!
        var u = scheduler.host.units[hIdx]
        u.positionX = UInt16(10 * 256 + 128); u.positionY = UInt16(10 * 256 + 128)
        u.actionID = Simulation.ActionID.harvest
        u.amount = 0
        scheduler.host.units[hIdx] = u
        scheduler.tickHarvesting()
        // Smoke-check: nil notifier path doesn't crash; level state
        // still tracks (tile either drained to thin or stayed thick
        // depending on the harvest gate).
        #expect([Simulation.SpiceMap.Level.thick, .thin].contains(
            scheduler.host.spiceMap?[UInt16(10 * 64 + 10)] ?? .notSand
        ))
    }
}
