import Foundation
import Testing
@testable import DuneIICore

@Suite("Core.Pos32")
struct TileMathTests {
    @Test("centered(at:) puts the packed tile at (x*256+128, y*256+128)")
    func centered() {
        let packed = PackedPosition(x: 5, y: 3)
        let p = Pos32.centered(at: packed)
        #expect(p.x == 5 * 256 + 128)
        #expect(p.y == 3 * 256 + 128)
    }

    @Test("distance is longest-axis + shortest-axis/2 (tile-space units)")
    func distanceMetric() {
        // Pure-horizontal: longest = 300, shortest = 0 → 300.
        #expect(Pos32.distance(Pos32(x: 128, y: 0), Pos32(x: 428, y: 0)) == 300)
        // Pure-diagonal: longest = 400, shortest = 400 → 400 + 200 = 600.
        #expect(Pos32.distance(Pos32(x: 0, y: 0), Pos32(x: 400, y: 400)) == 600)
        // Skewed: dx=300, dy=100 → longest=300, shortest=100, /2 = 50, sum = 350.
        #expect(Pos32.distance(Pos32(x: 0, y: 0), Pos32(x: 300, y: 100)) == 350)
        // Symmetric.
        #expect(
            Pos32.distance(Pos32(x: 300, y: 100), Pos32(x: 0, y: 0)) ==
            Pos32.distance(Pos32(x: 0, y: 0), Pos32(x: 300, y: 100))
        )
    }

    @Test("direction is 0/64/128/192 at the four cardinals")
    func cardinalDirections() {
        let origin = Pos32(x: 1000, y: 1000)
        // OpenDUNE quadrant table: up=0, right=64, down=128, left=192.
        #expect(Pos32.direction(from: origin, to: Pos32(x: 1000, y: 0)) == 0)      // up
        #expect(Pos32.direction(from: origin, to: Pos32(x: 2000, y: 1000)) == 64)  // right
        #expect(Pos32.direction(from: origin, to: Pos32(x: 1000, y: 2000)) == 128) // down
        #expect(Pos32.direction(from: origin, to: Pos32(x: 0, y: 1000)) == 192)    // left
    }

    @Test("Pos32.of resolves .unit / .structure / .tile / .none against host pools")
    func poolResolution() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 4, type: 0, houseID: 0)
        var slot = units[4]
        slot.positionX = 1234
        slot.positionY = 5678
        units[4] = slot

        var structures = Simulation.StructurePool()
        structures.allocate(at: 2, type: 0, houseID: 0)
        var s = structures[2]
        s.positionX = 987
        s.positionY = 654
        structures[2] = s

        let host = Scripting.Host(
            units: units, structures: structures,
            currentObject: nil, texts: [], textLog: [], voiceLog: []
        )

        let unitPos = Pos32.of(Scripting.EncodedIndex.unit(4), host: host)
        #expect(unitPos == Pos32(x: 1234, y: 5678))

        let structurePos = Pos32.of(Scripting.EncodedIndex.structure(2), host: host)
        #expect(structurePos == Pos32(x: 987, y: 654))

        // Tile: raw = 0xC000 | (x<<1) | (y<<8). x=3, y=5 → packed = 5*64+3 = 323;
        // centred at (3*256+128, 5*256+128) = (896, 1408).
        let tileRaw: UInt16 = 0xC000 | (3 << 1) | (5 << 8)
        let tilePos = Pos32.of(Scripting.EncodedIndex(raw: tileRaw), host: host)
        #expect(tilePos == Pos32(x: 896, y: 1408))

        #expect(Pos32.of(Scripting.EncodedIndex(raw: 0), host: host) == nil)
    }
}
