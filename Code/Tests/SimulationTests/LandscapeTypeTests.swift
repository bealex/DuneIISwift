import Foundation
import Testing
import DuneIIFormats
import DuneIIWorld
@testable import DuneIISimulation

/// Golden parity for `Map_GetLandscapeType`: generate a map from a seed (bit-exact) and classify every
/// tile, comparing against the oracle's per-tile landscape-type grid (`lst` in
/// `createlandscape-golden.jsonl`, dumped right after `Map_CreateLandscape`).
@Suite("Map_GetLandscapeType golden parity")
struct LandscapeTypeTests {
    struct Row: Decodable { let seed: UInt32; let lst: String }

    @Test("landscapeType matches the oracle for every tile of every seed")
    func landscapeTypes() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }     // Code/Tests/SimulationTests/ → repo root
        let iconMap = try IconMap(Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let fixture = repo.appendingPathComponent("Code/Tests/WorldTests/Fixtures/createlandscape-golden.jsonl")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        let rows = text.split(separator: "\n").map { try! JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        #expect(rows.count == 4)

        let nibbles = Array("0123456789abcdef")
        let map: any MapPrimitives = DefaultMapPrimitives()
        for row in rows {
            var state = GameState()
            state.tileIDs = TileIDs(iconMap: iconMap) ?? TileIDs()
            state.createLandscape(seed: row.seed, iconMap: iconMap)

            let expected = Array(row.lst)
            #expect(expected.count == 4096)
            var ok = true
            for i in 0 ..< 4096 {
                let type = map.landscapeType(state.map[i], tileIDs: state.tileIDs)
                if nibbles[type.rawValue] != expected[i] { ok = false; break }
            }
            #expect(ok, "seed \(row.seed)")
        }
    }
}
