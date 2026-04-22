import Foundation
import Testing
@testable import DuneIICore

@Suite("Spice-bloom detonation — unit removal + circle fill + tile reset")
struct BloomTests {

    // MARK: Pure `Bloom.explodeSpice` tests

    @Test("detonation frees the walking unit + overrides bloom tile to sand")
    func detonationRemovesUnitAndResetsTile() {
        var overrides: [(UInt16, UInt16)] = []
        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            spiceMap: Simulation.SpiceMap()
        )
        host.groundTileOverride = { packed, tileID in
            overrides.append((packed, tileID))
        }
        let idx = host.units.allocate(at: 0, type: 4 /* infantry */,
                                      houseID: Simulation.House.atreides)!
        var u = host.units[idx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        host.units[idx] = u

        Simulation.Bloom.explodeSpice(
            packed: UInt16(10 * 64 + 10),
            unitIndex: idx,
            sandTileID: 127,
            host: host,
            rng: { 0 }
        )

        #expect(host.units[idx].isUsed == false)
        #expect(overrides.count == 1)
        #expect(overrides[0].0 == UInt16(10 * 64 + 10))
        #expect(overrides[0].1 == 127)
    }

    @Test("spawns a tremor explosion at the bloom tile")
    func detonationSpawnsExplosion() {
        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            spiceMap: Simulation.SpiceMap()
        )
        let idx = host.units.allocate(at: 0, type: 13,
                                      houseID: Simulation.House.atreides)!
        var u = host.units[idx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        host.units[idx] = u

        Simulation.Bloom.explodeSpice(
            packed: UInt16(10 * 64 + 10),
            unitIndex: idx,
            sandTileID: 127,
            host: host,
            rng: { 0 }
        )

        let active = host.explosions.slots.filter { $0.isActive }
        #expect(active.count == 1)
        #expect(active.first?.type == Simulation.ExplosionType.spiceBloomTremor.rawValue)
    }

    @Test("circle fill seeds spice on sandy cells around the centre (rng=0 accepts edges)")
    func circleFillPaintsSpice() {
        // Build a SpiceMap where every cell is sandy (bare) so the
        // fill can actually deposit. Uses the landscape-closure init
        // with `.normalSand` everywhere → all cells `.bare`.
        var host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            spiceMap: Simulation.SpiceMap { _ in .normalSand }
        )
        // Allocate a dummy unit to act as trigger; it gets freed.
        let idx = host.units.allocate(at: 0, type: 13,
                                      houseID: Simulation.House.atreides)!
        var u = host.units[idx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        host.units[idx] = u
        host = Self.freshHost(host: host)

        Simulation.Bloom.explodeSpice(
            packed: UInt16(10 * 64 + 10),
            unitIndex: idx,
            sandTileID: 127,
            host: host,
            rng: { 0 }  // edge cells accepted (rng & 1 == 0)
        )

        guard let map = host.spiceMap else { Issue.record("no spice map"); return }
        // Centre tile gets +1 in the radius loop AND +1 in the tail
        // `Map_ChangeSpiceAmount(packed, 1)` — matches OpenDUNE's
        // `Map_FillCircleWithSpice`. bare → thin → thick.
        #expect(map[UInt16(10 * 64 + 10)] == .thick)
        // A neighbour 1 tile from centre (inside radius) just gets +1.
        #expect(map[UInt16(11 * 64 + 10)] == .thin)
        #expect(map[UInt16(10 * 64 + 11)] == .thin)
        // A cell 10 tiles away (outside radius 5) stays bare.
        #expect(map[UInt16(20 * 64 + 20)] == .bare)
    }

    // MARK: Scheduler integration

    @Test("tickBloomDetonation triggers on a non-sandworm standing on a bloom tile")
    func schedulerDetectsBloom() {
        let bloomByte = UInt8(LandscapeType.bloomField.rawValue)
        let sandByte = UInt8(LandscapeType.normalSand.rawValue)
        // Bloom at tile (10, 10); everywhere else is sand.
        let landscapeAt: (UInt16) -> UInt8 = { packed in
            packed == UInt16(10 * 64 + 10) ? bloomByte : sandByte
        }
        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            landscapeAt: landscapeAt,
            spiceMap: Simulation.SpiceMap { _ in .normalSand }
        )
        let idx = host.units.allocate(at: 0, type: 13 /* Trike */,
                                      houseID: Simulation.House.atreides)!
        var u = host.units[idx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        host.units[idx] = u

        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        var scheduler = Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm,
            harvestRNG: { 0 }
        )
        scheduler.bloomSandTileID = 127

        scheduler.tickBloomDetonation()

        #expect(host.units[idx].isUsed == false)
    }

    @Test("sandworm standing on bloom is NOT detonated")
    func sandwormImmune() {
        let bloomByte = UInt8(LandscapeType.bloomField.rawValue)
        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            landscapeAt: { _ in bloomByte },
            spiceMap: Simulation.SpiceMap()
        )
        let idx = host.units.allocate(at: 0, type: 25 /* SANDWORM */,
                                      houseID: Simulation.House.atreides)!
        var u = host.units[idx]
        u.positionX = UInt16(10 * 256 + 128)
        u.positionY = UInt16(10 * 256 + 128)
        host.units[idx] = u
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        var scheduler = Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm,
            harvestRNG: { 0 }
        )
        scheduler.bloomSandTileID = 127
        scheduler.tickBloomDetonation()
        #expect(host.units[idx].isUsed == true)   // unchanged
    }

    @Test("bloomSandTileID == 0 disables the pass (no detonation)")
    func disabledByDefault() {
        let bloomByte = UInt8(LandscapeType.bloomField.rawValue)
        let host = Scripting.Host(
            playerHouseID: Simulation.House.atreides,
            landscapeAt: { _ in bloomByte },
            spiceMap: Simulation.SpiceMap()
        )
        let idx = host.units.allocate(at: 0, type: 13,
                                      houseID: Simulation.House.atreides)!
        var u = host.units[idx]
        u.positionX = UInt16(10 * 256 + 128); u.positionY = UInt16(10 * 256 + 128)
        host.units[idx] = u
        let program = Formats.Emc.Program.empty
        let vm = Scripting.VM(program: program, functions: Array(repeating: nil, count: 64))
        var scheduler = Simulation.Scheduler(
            host: host, unitVM: vm, structureVM: vm, teamVM: vm,
            harvestRNG: { 0 }
        )
        // bloomSandTileID defaults to 0.
        scheduler.tickBloomDetonation()
        #expect(host.units[idx].isUsed == true)
    }

    /// Returns a scripting host identity — we already hold a reference
    /// (Host is a class), so this is just a passthrough helper kept
    /// for readability in the circle-fill test.
    private static func freshHost(host: Scripting.Host) -> Scripting.Host { host }
}
