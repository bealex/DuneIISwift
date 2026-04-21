import Foundation
import Testing
@testable import DuneIICore

@Suite("Core.ScenarioWorld")
struct ScenarioWorldTests {
    @Test("stamping a structure marks the cell as occupied")
    func stampStructure() throws {
        let src = """
        [BASIC]
        TimeOut=0

        [STRUCTURES]
        ID000=Atreides,Const Yard,256,1630
        """
        let world = try makeWorld(iniText: src)
        let tile = PackedPosition(raw: 1630).tile
        #expect(world.map[Int(tile.x), Int(tile.y)].hasStructure == true)
        #expect(world.structure(at: PackedPosition(raw: 1630))?.structureType == .constructionYard)
    }

    @Test("GEN-keyed slab writes builtSlabTileID into the ground")
    func stampSlab() throws {
        let src = """
        [BASIC]
        TimeOut=0

        [STRUCTURES]
        GEN1000=Atreides,Concrete Slab,256
        """
        let world = try makeWorld(iniText: src)
        let tile = PackedPosition(raw: 1000).tile
        let cell = world.map[Int(tile.x), Int(tile.y)]
        #expect(cell.groundTileID == world.resolver.builtSlabTileID)
    }

    @Test("units at the same packed position are both retrievable")
    func unitsAtSamePosition() throws {
        let src = """
        [BASIC]
        TimeOut=0

        [UNITS]
        ID000=Atreides,Soldier,256,500,0,Guard
        ID001=Ordos,Trooper,256,500,0,Ambush
        """
        let world = try makeWorld(iniText: src)
        let at500 = world.units(at: PackedPosition(raw: 500))
        #expect(at500.count == 2)
        #expect(Set(at500.map { $0.unitType }) == Set([.soldier, .trooper]))
    }

    @Test("MapField seeds survive the world build")
    func preserveMapField() throws {
        let src = """
        [BASIC]
        TimeOut=0

        [MAP]
        Field=1300
        Bloom=100
        Seed=42
        """
        let world = try makeWorld(iniText: src)
        let spiceTile = PackedPosition(raw: 1300).tile
        #expect(world.map[Int(spiceTile.x), Int(spiceTile.y)].spiceAmount > 0)
        let bloomTile = PackedPosition(raw: 100).tile
        #expect(world.map[Int(bloomTile.x), Int(bloomTile.y)].groundTileID == world.resolver.bloomTileID)
    }

    @Test("real SCENA001.INI stamps the Atreides construction yard at 1630")
    func realScenarioStamping() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("SCENARIO.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let body = archive.body(named: "SCENA001.INI") else { return }
        let scenario = try Scenario(iniData: body)
        let resolver = TileResolver(iconMap: try makeSyntheticIconMap())
        let world = ScenarioWorld(scenario: scenario, resolver: resolver)
        let tile = PackedPosition(raw: 1630).tile
        #expect(world.map[Int(tile.x), Int(tile.y)].hasStructure == true)
    }

    // MARK: - helpers

    private func makeWorld(iniText: String) throws -> ScenarioWorld {
        let scenario = try Scenario(iniData: Data(iniText.utf8))
        let resolver = TileResolver(iconMap: try makeSyntheticIconMap())
        return ScenarioWorld(scenario: scenario, resolver: resolver)
    }

    private func makeSyntheticIconMap() throws -> Formats.IconMap {
        // LANDSCAPE group needs 81 entries — `Map.Generator.generate`
        // indexes up to 80 via `_landscapeSpriteMap`.
        var u16s: [UInt16] = Array(repeating: 28, count: 28)
        u16s[6] = 28      // WALLS
        u16s[7] = 60      // FOG_OF_WAR
        u16s[8] = 92      // CONCRETE_SLAB
        u16s[9] = 124     // LANDSCAPE (81 entries)
        u16s[10] = 205    // SPICE_BLOOM
        for i in 11..<27 { u16s[i] = 237 }
        u16s[27] = 237
        func run(_ start: UInt16, _ count: Int) -> [UInt16] {
            (0..<count).map { start + UInt16($0) }
        }
        u16s.append(contentsOf: run(4000, 32))      // walls
        u16s.append(contentsOf: run(5000, 32))      // fog
        u16s.append(contentsOf: run(3000, 32))      // slab
        u16s.append(contentsOf: run(1000, 81))      // landscape
        u16s.append(contentsOf: run(2000, 32))      // spice bloom
        var data = Data()
        for v in u16s {
            data.append(UInt8(v & 0xFF))
            data.append(UInt8(v >> 8))
        }
        return try Formats.IconMap.decode(data)
    }
}
