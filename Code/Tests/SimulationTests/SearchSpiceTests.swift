import Foundation
import Testing
import DuneIIFormats
import DuneIIWorld
@testable import DuneIISimulation

/// Golden parity for `Map_SearchSpice`: generate a map from a seed (no units/structures placed) and
/// search for the nearest harvestable spice from several query tiles + radii, comparing the resulting
/// packed position against the oracle (`Golden_SearchSpice` → `searchspice-golden.jsonl`, at the
/// default `mapScale` 0). Covers both found (seed 0x1234) and not-found (seed 0) cases.
@Suite("Map_SearchSpice golden parity")
struct SearchSpiceTests {
    struct Row: Decodable { let seed: UInt32; let packed: UInt16; let radius: UInt16; let result: UInt16 }

    @Test("searchSpice matches the oracle for every query")
    func searchSpice() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }     // Code/Tests/SimulationTests/ → repo root
        let iconMap = try IconMap(Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let fixture = repo.appendingPathComponent("Code/Tests/WorldTests/Fixtures/searchspice-golden.jsonl")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        let rows = text.split(separator: "\n").map { try! JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        #expect(!rows.isEmpty)

        let map: any MapPrimitives = DefaultMapPrimitives()
        // The generated landscape depends only on the seed, so cache one GameState per seed.
        var bySeed: [UInt32: GameState] = [:]
        for row in rows {
            let state = bySeed[row.seed] ?? {
                var s = GameState()
                s.tileIDs = TileIDs(iconMap: iconMap) ?? TileIDs()
                s.createLandscape(seed: row.seed, iconMap: iconMap)
                bySeed[row.seed] = s
                return s
            }()
            let result = map.searchSpice(row.packed, radius: row.radius, in: state)
            #expect(result == row.result, "seed \(row.seed) packed \(row.packed) radius \(row.radius)")
        }
    }
}
