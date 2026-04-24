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

    @Test("Pos32.targetTile adds layoutTileDiff for structure encodings (Tools_Index_GetTile parity)")
    func targetTileLayoutAdjustsStructureCenter() throws {
        // CYARD (type 8, layout s2x2) stored anchor at (7680, 6400).
        // OpenDUNE's `Tools_Index_GetTile` returns anchor + (256, 256)
        // for 2x2 layouts — the layout-adjusted centre.
        var structures = Simulation.StructurePool()
        structures.allocate(at: 0, type: 8, houseID: 0)
        var s = structures[0]
        s.positionX = 7680
        s.positionY = 6400
        structures[0] = s

        let host = Scripting.Host(structures: structures)

        let tgt = Pos32.targetTile(
            Scripting.EncodedIndex.structure(0), host: host
        )
        #expect(tgt == Pos32(x: 7680 + 0x100, y: 6400 + 0x100),
                "s2x2 tileDiff (0x100,0x100) must land on layout-adjusted centre")
    }

    @Test("Pos32.targetTile falls through to Pos32.of for non-structure encodings")
    func targetTileFallsThroughForUnitsAndTiles() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 4, type: 0, houseID: 0)
        var u = units[4]
        u.positionX = 1234
        u.positionY = 5678
        units[4] = u
        let host = Scripting.Host(units: units)
        let unitPos = Pos32.targetTile(Scripting.EncodedIndex.unit(4), host: host)
        #expect(unitPos == Pos32(x: 1234, y: 5678))

        let tilePos = Pos32.targetTile(
            Scripting.EncodedIndex.tile(packed: 64 &* 5 &+ 3), host: host
        )
        #expect(tilePos == Pos32(x: 896, y: 1408))
    }

    @Test("Pos32.distance(from:toEncoded:host:) picks the structure's edge tile for a 2x2 layout")
    func distanceToEncodedEdgeAdjustsStructures() throws {
        // u37 attacker at (7651, 6941). CYARD (s2x2, type 8) at
        // (7680, 6400). Direction from attacker to centre (7680,
        // 6400) is ≈ N (dy=-541, dx=29) → orient8=0 → edgeIdx=4 →
        // s2x2 offsets[4] = 65 (anchor + 1 right + 1 south). CYARD
        // anchor tile = (30, 25) packed = 1630 → edge = 1695 =
        // (31, 26) → position (8064, 6784). Distance from (7651,
        // 6941) to (8064, 6784) = max(413, 157) + min/2 = 491.
        var structures = Simulation.StructurePool()
        structures.allocate(at: 0, type: 8, houseID: 0)
        var s = structures[0]
        s.positionX = 7680
        s.positionY = 6400
        structures[0] = s
        let host = Scripting.Host(structures: structures)

        let attacker = Pos32(x: 7651, y: 6941)
        let edge = Pos32.distance(
            from: attacker,
            toEncoded: Scripting.EncodedIndex.structure(0),
            host: host
        )
        #expect(edge == 491,
                "structure-target distance must measure to nearest edge tile, not centre")
    }

    @Test("Pos32.distance(from:toEncoded:host:) returns same result as centre distance for unit targets")
    func distanceToEncodedNoAdjustForUnits() throws {
        var units = Simulation.UnitPool()
        units.allocate(at: 10, type: 0, houseID: 0)
        var u = units[10]
        u.positionX = 2000
        u.positionY = 3000
        units[10] = u
        let host = Scripting.Host(units: units)

        let from = Pos32(x: 1000, y: 1000)
        let centre = Pos32(x: 2000, y: 3000)
        let expected = Pos32.distance(from, centre)
        let actual = Pos32.distance(
            from: from,
            toEncoded: Scripting.EncodedIndex.unit(10),
            host: host
        )
        #expect(actual == expected)
    }
}
