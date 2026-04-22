import Foundation
import Testing
@testable import DuneIICore

@Suite("Simulation.SpiceMap — runtime spice state + Map_ChangeSpiceAmount port")
struct SpiceMapTests {

    // MARK: Transitions

    @Test("apply(-1) drains THICK→THIN; second -1 drains THIN→BARE; third -1 no-op (BARE)")
    func drainChainStopsAtBare() {
        var map = Simulation.SpiceMap()
        // Seed a thick-spice tile.
        _ = map.apply(delta: +1, at: 0)  // bare → thin
        _ = map.apply(delta: +1, at: 0)  // thin → thick
        #expect(map[0] == .thick)

        let a = map.apply(delta: -1, at: 0)
        #expect(a == .thin)
        let b = map.apply(delta: -1, at: 0)
        #expect(b == .bare)
        let c = map.apply(delta: -1, at: 0)
        #expect(c == .bare)
    }

    @Test("apply(+1) climbs BARE→THIN→THICK; further +1 no-op (THICK)")
    func addChainStopsAtThick() {
        var map = Simulation.SpiceMap()
        let a = map.apply(delta: +1, at: 100)
        #expect(a == .thin)
        let b = map.apply(delta: +1, at: 100)
        #expect(b == .thick)
        let c = map.apply(delta: +1, at: 100)
        #expect(c == .thick)
    }

    @Test("apply(0) is a no-op regardless of level")
    func zeroDeltaNoOp() {
        var map = Simulation.SpiceMap()
        _ = map.apply(delta: +1, at: 10)
        #expect(map[10] == .thin)
        let after = map.apply(delta: 0, at: 10)
        #expect(after == .thin)
        #expect(map[10] == .thin)
    }

    @Test("apply on notSand tile is inert regardless of sign")
    func notSandInert() {
        var map = Simulation.SpiceMap()
        // Force tile 50 to notSand via direct seeding — emulates rock.
        map = simulateNotSand(at: 50, base: map)
        let a = map.apply(delta: +1, at: 50)
        let b = map.apply(delta: -1, at: 50)
        #expect(a == .notSand)
        #expect(b == .notSand)
    }

    /// Helper: make a SpiceMap whose tile at `index` is `.notSand` by
    /// initializing from a stub landscape closure. The public API
    /// doesn't expose a direct setter (by design: transitions only
    /// happen via `apply`).
    private func simulateNotSand(at index: Int, base: Simulation.SpiceMap) -> Simulation.SpiceMap {
        Simulation.SpiceMap { i in
            i == index ? .entirelyMountain : .normalSand
        }
    }

    // MARK: Construction from tile grid

    @Test("init(landscapeAt:) maps spice/thickSpice landscapes to thin/thick levels")
    func initFromLandscapeClosure() {
        let map = Simulation.SpiceMap { i in
            switch i {
            case 0: return .spice
            case 1: return .thickSpice
            case 2: return .entirelyRock
            default: return .normalSand
            }
        }
        #expect(map[0] == .thin)
        #expect(map[1] == .thick)
        #expect(map[2] == .notSand)
        #expect(map[3] == .bare)
    }

    // MARK: landscapeByte bridge

    @Test("landscapeByte returns the right raw for each level")
    func landscapeByteMapping() {
        var map = Simulation.SpiceMap()
        #expect(map.landscapeByte(at: 0) == UInt8(LandscapeType.normalSand.rawValue))
        _ = map.apply(delta: +1, at: 0)
        #expect(map.landscapeByte(at: 0) == UInt8(LandscapeType.spice.rawValue))
        _ = map.apply(delta: +1, at: 0)
        #expect(map.landscapeByte(at: 0) == UInt8(LandscapeType.thickSpice.rawValue))
    }

    // MARK: End-to-end with harvestSpiceStep

    @Test("harvestSpiceStep drives SpiceMap: repeated drains take a THICK tile to BARE")
    func drivesHarvestStep() {
        var upool = Simulation.UnitPool()
        let hIdx = upool.allocate(in: 16...19, type: 16, houseID: Simulation.House.atreides)!
        var u = upool[hIdx]
        u.positionX = UInt16(5 * 256 + 128)
        u.positionY = UInt16(5 * 256 + 128)
        u.amount = 0
        upool[hIdx] = u

        var map = Simulation.SpiceMap()
        _ = map.apply(delta: +1, at: UInt16(5 * 64 + 5))
        _ = map.apply(delta: +1, at: UInt16(5 * 64 + 5))
        #expect(map[5, 5] == .thick)

        // Force drain every call via rng = 0,0 (jitter=0, gate=0)
        var rng = [UInt8](repeating: 0, count: 128)
        var i = 0
        let next: () -> UInt8 = { defer { i += 1 }; return rng[i % rng.count] }

        // First drain: thick → thin
        _ = Simulation.Units.harvestSpiceStep(
            harvesterIndex: hIdx, units: &upool,
            landscapeAt: { map.landscapeByte(at: $0) },
            changeSpice: { p, d in map.apply(delta: d, at: p) },
            rng: next
        )
        #expect(map[5, 5] == .thin)

        // Second drain: thin → bare
        _ = Simulation.Units.harvestSpiceStep(
            harvesterIndex: hIdx, units: &upool,
            landscapeAt: { map.landscapeByte(at: $0) },
            changeSpice: { p, d in map.apply(delta: d, at: p) },
            rng: next
        )
        #expect(map[5, 5] == .bare)

        // Third call: tile is bare → harvest returns 0 without mutation.
        let ret = Simulation.Units.harvestSpiceStep(
            harvesterIndex: hIdx, units: &upool,
            landscapeAt: { map.landscapeByte(at: $0) },
            changeSpice: { p, d in map.apply(delta: d, at: p) },
            rng: next
        )
        #expect(ret == 0)
        #expect(map[5, 5] == .bare)

    }
}
