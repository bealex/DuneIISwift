import Foundation
import Testing
import DuneIIFormats
import DuneIIWorld
@testable import DuneIISimulation

/// Golden parity for `Map_ChangeSpiceAmount` (+ `Map_FixupSpiceEdges`): generate a map from a seed,
/// then grow (`dir = +1`) or deplete (`dir = -1`) spice on every tile in packed order and compare the
/// resulting ground grid against the oracle (`Golden_Spice` in `parity.c`, `spice-golden.jsonl`). The
/// per-tile pass is order-dependent (a tile's edge sprite reflects its current neighbours), so both
/// sides must iterate 0…4095 ascending — which they do.
@Suite("Map_ChangeSpiceAmount golden parity")
struct SpiceTests {
    struct Row: Decodable { let seed: UInt32; let dir: Int16; let ground: String }

    @Test("changeSpiceAmount reproduces the oracle's ground grid per seed/direction")
    func changeSpiceAmount() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }     // Code/Tests/SimulationTests/ → repo root
        let iconMap = try IconMap(Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let fixture = repo.appendingPathComponent("Code/Tests/WorldTests/Fixtures/spice-golden.jsonl")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        let rows = text.split(separator: "\n").map { try! JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        #expect(rows.count == 4)

        let map: any MapPrimitives = DefaultMapPrimitives()
        for row in rows {
            var state = GameState()
            state.tileIDs = TileIDs(iconMap: iconMap) ?? TileIDs()
            state.createLandscape(seed: row.seed, iconMap: iconMap)
            state.iconMap = iconMap

            for i in 0 ..< 4096 { map.changeSpiceAmount(UInt16(i), row.dir, in: &state) }

            var hex = ""
            hex.reserveCapacity(4096 * 2)
            for i in 0 ..< 4096 { hex += String(format: "%02x", state.map[i].groundTileID & 0xFF) }
            #expect(hex == row.ground, "seed \(row.seed) dir \(row.dir)")
        }
    }
}
