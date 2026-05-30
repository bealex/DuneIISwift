import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
@testable import DuneIIWorld

/// Loads a real committed scenario `.INI` (+ `ICON.MAP`) into a `GameState` and checks the map +
/// objects are populated. SCENA001 = Atreides mission 1 (`[MAP] Seed=353`, `[BASIC] MapScale=1`).
@Suite("Scenario loader")
struct ScenarioLoaderTests {
    @Test("SCENA001 loads landscape + units + structures")
    func loadScena001() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let iconMap = try IconMap(Data(contentsOf: root.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let ini = try Ini(Data(contentsOf: root.appendingPathComponent("Resources/Scenarios/SCENA001.INI")))

        var state = GameState()
        state.loadScenario(ini: ini, iconMap: iconMap)

        #expect(state.mapScale == 1)
        #expect(state.tileIDs.landscape == 127)
        // Landscape was generated (not all tiles are the same sprite).
        #expect(Set(state.map.map(\.groundTileID)).count > 1)
        // Units placed (the file has an Atreides Trike + soldiers, an Ordos squad, …).
        #expect(state.unitFindArray.count > 3)
        let trike = state.units.first { $0.o.flags.contains(.used) && $0.o.type == UInt8(UnitType.trike.rawValue) }
        let placedTrike = try #require(trike)
        #expect(placedTrike.o.position == Tile32.unpack(1501))
        // A construction yard structure (ID000=Atreides,Const Yard,256,1630).
        let cy = state.structures.first {
            $0.o.flags.contains(.used) && $0.o.type == UInt8(StructureType.constructionYard.rawValue)
        }
        #expect(cy != nil)
        // A structure stores its tile *corner* (the 0x80 sub-tile stripped), not the centred unpack
        // (`Structure_Place`: `position &= 0xFF00`) — units centre, structures don't.
        #expect(cy?.o.position == Tile32(x: Tile32.unpack(1630).x & 0xFF00, y: Tile32.unpack(1630).y & 0xFF00))
        #expect(cy?.o.position.packed == 1630)   // same packed tile either way
    }
}
