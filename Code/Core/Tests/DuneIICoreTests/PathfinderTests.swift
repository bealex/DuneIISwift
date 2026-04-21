import Foundation
import Testing
@testable import DuneIICore

@Suite("Simulation.Pathfinder")
struct PathfinderTests {
    @Test("packedTile converts pos32 pixel coords to tile indexes")
    func packedTileConversion() {
        // Tile (5, 3) centred → pos32 (5*256+128, 3*256+128) = (1408, 896).
        let packed = Simulation.Pathfinder.packedTile(x: 1408, y: 896)
        #expect(packed == 3 * 64 + 5)
    }

    @Test("packedDistance is longest + shortest/2 in tile units")
    func packedDistanceMetric() {
        // Tile (0,0) to (10, 0) → distance 10.
        let a: UInt16 = 0
        let b: UInt16 = 10
        #expect(Simulation.Pathfinder.packedDistance(from: a, to: b) == 10)
        // Diagonal (0,0) to (4,3) → longest=4, shortest=3 → 4 + 1 = 5.
        let c: UInt16 = 0
        let d: UInt16 = UInt16(3 * 64 + 4)
        #expect(Simulation.Pathfinder.packedDistance(from: c, to: d) == 5)
    }

    @Test("directionPacked returns the correct OpenDUNE-style angle at the four cardinals")
    func directionPackedCardinals() {
        let origin: UInt16 = UInt16(10 * 64 + 10)
        // Up: (10, 5) → 0x00 (north)
        #expect(Simulation.Pathfinder.directionPacked(from: origin, to: UInt16(5 * 64 + 10)) == 0x00)
        // Right: (10, 15) → 0x40 (east)
        #expect(Simulation.Pathfinder.directionPacked(from: origin, to: UInt16(10 * 64 + 15)) == 0x40)
        // Down: (15, 10) → 0x80 (south)
        #expect(Simulation.Pathfinder.directionPacked(from: origin, to: UInt16(15 * 64 + 10)) == 0x80)
        // Left: (10, 5) → 0xC0 (west)
        #expect(Simulation.Pathfinder.directionPacked(from: origin, to: UInt16(10 * 64 + 5)) == 0xC0)
    }

    @Test("findRoute produces a non-empty route on an open map")
    func pathfinderOpenMap() {
        // Every tile costs 128 (walkable).
        let scorer: Simulation.Pathfinder.TileEnterScore = { _, _ in 128 }
        let src: UInt16 = UInt16(10 * 64 + 10)
        let dst: UInt16 = UInt16(10 * 64 + 15)   // 5 tiles east
        let result = Simulation.Pathfinder.findRoute(src: src, dst: dst, bufferSize: 40, score: scorer)
        #expect(result.size > 0)
        #expect(result.size <= 14)
        // Walk the route and confirm we hit dst.
        var packed = src
        for i in 0..<result.size {
            let dir = result.buffer[i]
            if dir == 0xFF { break }
            packed = UInt16(truncatingIfNeeded:
                Int32(packed) + Simulation.Pathfinder.mapDirection[Int(dir)])
        }
        #expect(packed == dst)
    }

    @Test("findRoute returns the 0xFF-first route when no path exists")
    func pathfinderImpassable() {
        // Every tile is impassable.
        let scorer: Simulation.Pathfinder.TileEnterScore = { _, _ in 256 }
        let src: UInt16 = UInt16(10 * 64 + 10)
        let dst: UInt16 = UInt16(10 * 64 + 15)
        let result = Simulation.Pathfinder.findRoute(src: src, dst: dst, bufferSize: 40, score: scorer)
        // OpenDUNE's `routeSize` counts the 0xFF terminator, so an empty
        // route has size 1; `buffer[0] == 0xFF` is the canonical "no
        // route" marker (which is what `Script_Unit_CalculateRoute`
        // checks).
        #expect(result.buffer[0] == 0xFF)
    }

    @Test("findRoute routes around a thin wall")
    func pathfinderWall() {
        // Build a vertical wall at column 12 rows 8..14. Everything else is cost 128.
        let scorer: Simulation.Pathfinder.TileEnterScore = { packed, _ in
            let x = Int(packed & 0x3F)
            let y = Int((packed >> 6) & 0x3F)
            if x == 12, (8...14).contains(y) { return 256 }
            return 128
        }
        let src: UInt16 = UInt16(11 * 64 + 10)
        let dst: UInt16 = UInt16(11 * 64 + 14)
        let result = Simulation.Pathfinder.findRoute(src: src, dst: dst, bufferSize: 40, score: scorer)
        #expect(result.size > 0)
        // Trace the route and confirm it reaches dst without crossing the wall.
        var packed = src
        var crossedWall = false
        for i in 0..<result.size {
            let dir = result.buffer[i]
            if dir == 0xFF { break }
            packed = UInt16(truncatingIfNeeded:
                Int32(packed) + Simulation.Pathfinder.mapDirection[Int(dir)])
            let x = Int(packed & 0x3F)
            let y = Int((packed >> 6) & 0x3F)
            if x == 12, (8...14).contains(y) { crossedWall = true }
        }
        #expect(!crossedWall)
        #expect(packed == dst)
    }

    @Test("Scheduler route-follower advances along a filled route")
    func schedulerFollowsRoute() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 0, type: 13, houseID: 0) // Trike
        var u = units[0]
        // Start at tile (10, 10): pos32 (10*256+128, 10*256+128) = (2688, 2688).
        u.positionX = 2688
        u.positionY = 2688
        u.speed = 255
        u.route[0] = 2    // East step
        u.route[1] = 2    // East step
        u.route[2] = 0xFF
        // targetMove != 0 so the fallback branch isn't used; we follow the route.
        u.targetMove = UInt16(0xC000) | (20 << 1) | (10 << 8)  // some tile (20, 10)
        units[0] = u

        let host = Scripting.Host(
            units: units, structures: .init(),
            currentObject: nil, texts: [], textLog: [], voiceLog: []
        )
        let emptyFunctions = [Scripting.VM.Function?](repeating: nil, count: 64)
        var scheduler = Simulation.Scheduler(
            host: host,
            unitVM: Scripting.VM(program: .empty, functions: emptyFunctions),
            structureVM: Scripting.VM(program: .empty, functions: emptyFunctions)
        )
        // Several ticks should consume both route entries.
        for _ in 0..<50 {
            scheduler.tick()
            if host.units[0].route[0] == 0xFF { break }
        }
        #expect(host.units[0].route[0] == 0xFF)
        // After consuming both steps east, we should be ~2 tiles east of start.
        #expect(host.units[0].positionX >= 2688 + 256)
    }
}
