import DuneIIFormats
import Foundation
import Testing

@testable import DuneIIWorld

/// Golden parity for `Map_CreateLandscape`: the seed-driven map generator. It is purely RNG-driven
/// (our `Random256` + `Tile_MoveByRandom` are bit-exact), so for a given seed the generated ground
/// grid matches OpenDUNE exactly. The oracle (`Golden_CreateLandscape`) loads the same committed
/// `ICON.MAP` and dumps the 4096 ground sprite IDs (low byte, 2 hex digits) per seed.
@Suite("Map generation golden parity")
struct MapGeneratorTests {
    struct Row: Decodable { let seed: UInt32; let ground: String }

    @Test("Map_CreateLandscape reproduces the oracle's ground grid per seed")
    func createLandscape() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }  // Code/Tests/WorldTests/ → repo root
        let iconMap = try IconMap(Data(contentsOf: root.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))

        let rows = GoldenFixture.decode("createlandscape-golden.jsonl", as: Row.self)
        #expect(rows.count == 4)
        for row in rows {
            var state = GameState()
            state.createLandscape(seed: row.seed, iconMap: iconMap)

            var hex = ""
            hex.reserveCapacity(4096 * 2)
            for i in 0 ..< 4096 { hex += String(format: "%02x", state.map[i].groundTileID & 0xFF) }
            #expect(hex == row.ground, "seed \(row.seed)")
        }
    }
}
