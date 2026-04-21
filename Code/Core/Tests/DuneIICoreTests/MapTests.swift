import Foundation
import Testing
@testable import DuneIICore

@Suite("Core.Map")
struct MapTests {
    @Test("empty map is 64×64 with zeroed cells")
    func emptyMap() {
        let map = Map.empty()
        #expect(Map.width == 64)
        #expect(Map.height == 64)
        #expect(map.cells.count == 64 * 64)
        #expect(map.cells.allSatisfy { $0.groundTileID == 0 && $0.spiceAmount == 0 })
    }

    @Test("TileResolver pre-computes landscape/bloom/slab/wall tile IDs")
    func tileResolverIDs() throws {
        let iconMap = try makeSyntheticIconMap()
        let resolver = TileResolver(iconMap: iconMap)
        // Landscape group: first tile ID of the group is `landscapeTileID`.
        #expect(resolver.landscapeTileID == 1000)
        // Spice bloom: first tile ID.
        #expect(resolver.bloomTileID == 2000)
        // Concrete slab: tile at offset 2 in the slab group.
        #expect(resolver.builtSlabTileID == 3002)
        // Walls: first tile ID.
        #expect(resolver.wallTileID == 4000)
    }

    @Test("landscapeType classifies built slab, wall, bloom, destroyed wall, and landscape ranges")
    func landscapeClassification() throws {
        let iconMap = try makeSyntheticIconMap()
        let resolver = TileResolver(iconMap: iconMap)

        // Built slab: ground == builtSlabTileID
        #expect(resolver.landscapeType(groundTileID: 3002, overlayTileID: 0, hasStructure: false) == .concreteSlab)
        // Bloom field: ground == bloomTileID
        #expect(resolver.landscapeType(groundTileID: 2000, overlayTileID: 0, hasStructure: false) == .bloomField)
        #expect(resolver.landscapeType(groundTileID: 2001, overlayTileID: 0, hasStructure: false) == .bloomField)
        // Wall range: wallTileID < ground < wallTileID + 75
        #expect(resolver.landscapeType(groundTileID: 4010, overlayTileID: 0, hasStructure: false) == .wall)
        // Destroyed wall: overlay == wallTileID
        #expect(resolver.landscapeType(groundTileID: 0, overlayTileID: 4000, hasStructure: false) == .destroyedWall)
        // Structure
        #expect(resolver.landscapeType(groundTileID: 1010, overlayTileID: 0, hasStructure: true) == .structure)
        // Landscape sprite 0 (offset 0 from landscapeTileID) → normalSand
        #expect(resolver.landscapeType(groundTileID: 1000, overlayTileID: 0, hasStructure: false) == .normalSand)
        // Landscape sprite 16 → entirelyRock per the lookup
        #expect(resolver.landscapeType(groundTileID: 1016, overlayTileID: 0, hasStructure: false) == .entirelyRock)
        // Out-of-range offset falls back to .entirelyRock
        #expect(resolver.landscapeType(groundTileID: 5000, overlayTileID: 0, hasStructure: false) == .entirelyRock)
    }

    @Test("applyMapField stamps seeds from Scenario.MapField")
    func applyMapField() throws {
        let iconMap = try makeSyntheticIconMap()
        let resolver = TileResolver(iconMap: iconMap)

        var map = Map.empty()
        var field = Scenario.MapField()
        // packed position 1630 = (y:25, x:30). Stamp a spice field there.
        field.initialSpiceFields = [1630]
        field.initialBlooms = [100]
        map.applyMapField(field, resolver: resolver)

        let spiceCell = map.cells[Int(PackedPosition(raw: 1630).tile.y) * 64 + Int(PackedPosition(raw: 1630).tile.x)]
        #expect(spiceCell.spiceAmount > 0)

        let bloomCell = map.cells[Int(PackedPosition(raw: 100).tile.y) * 64 + Int(PackedPosition(raw: 100).tile.x)]
        #expect(bloomCell.groundTileID == resolver.bloomTileID)
    }

    // MARK: - Helpers

    /// Hand-builds an IconMap where the groups we care about point at
    /// distinct, easy-to-read tile ID ranges so the test assertions speak
    /// in round numbers.
    private func makeSyntheticIconMap() throws -> Formats.IconMap {
        // Header: 28 u16 indices. Give WALLS, FOG_OF_WAR, CONCRETE_SLAB,
        // LANDSCAPE, SPICE_BLOOM each a 32-entry run so offset math is easy.
        var u16s: [UInt16] = Array(repeating: 28, count: 28)
        u16s[6] = 28   // WALLS: 28..59
        u16s[7] = 60   // FOG_OF_WAR: 60..91
        u16s[8] = 92   // CONCRETE_SLAB: 92..123
        u16s[9] = 124  // LANDSCAPE: 124..155
        u16s[10] = 156 // SPICE_BLOOM: 156..187
        for i in 11..<27 { u16s[i] = 188 }
        u16s[27] = 188 // sentinel

        // Fill the tile-ID runs. WALLS starts at 4000, FOG at 5000,
        // SLAB at 3000, LANDSCAPE at 1000, BLOOM at 2000.
        func run(_ startId: UInt16, _ count: Int) -> [UInt16] {
            (0..<count).map { UInt16(Int(startId) + $0) }
        }
        u16s.append(contentsOf: run(4000, 32)) // walls
        u16s.append(contentsOf: run(5000, 32)) // fog
        u16s.append(contentsOf: run(3000, 32)) // slab
        u16s.append(contentsOf: run(1000, 32)) // landscape
        u16s.append(contentsOf: run(2000, 32)) // spice bloom

        var data = Data()
        for v in u16s {
            data.append(UInt8(v & 0xFF))
            data.append(UInt8(v >> 8))
        }
        return try Formats.IconMap.decode(data)
    }
}
