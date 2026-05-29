import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
@testable import DuneIISimulation

/// Golden parity for the unit pathfinder (`Pathfinder` ↔ OpenDUNE `Script_Unit_Pathfinder`): on a map
/// generated from a seed, with a tank as the moving unit, the computed route (direction steps), its
/// `score`, and `routeSize` match the oracle (`Golden_Pathfinder` → `pathfinder-golden.jsonl`) for
/// every src→dst pair.
@Suite("Pathfinder golden parity")
struct PathfinderTests {
    struct Row: Decodable {
        let seed: UInt32; let src: UInt16; let dst: UInt16
        let score: Int16; let routeSize: Int; let route: [UInt8]
    }

    @Test("pathfinder routes match the oracle")
    func golden() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }   // Code/Tests/SimulationTests → repo root
        let iconMap = try IconMap(Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let fixture = repo.appendingPathComponent("Code/Tests/WorldTests/Fixtures/pathfinder-golden.jsonl")
        let rows = try String(contentsOf: fixture, encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        #expect(!rows.isEmpty)

        let pf = Pathfinder()
        // The generated map depends only on the seed; one GameState (+ a tank) per seed.
        var bySeed: [UInt32: (GameState, Int)] = [:]
        for row in rows {
            let (state, slot) = bySeed[row.seed] ?? {
                var s = GameState()
                s.playerHouseID = 0
                s.houses[0].unitCountMax = 100
                s.tileIDs = TileIDs(iconMap: iconMap) ?? TileIDs()
                s.createLandscape(seed: row.seed, iconMap: iconMap)
                let tank = s.unitAllocate(index: 0, type: UInt8(UnitType.tank.rawValue), houseID: 0)!
                bySeed[row.seed] = (s, tank)
                return (s, tank)
            }()

            let result = pf.pathfind(src: row.src, dst: row.dst, unit: state.units[slot], bufferSize: 40, in: state)
            let dirs = Array(result.buffer.prefix(while: { $0 != 0xFF }))
            #expect(dirs == row.route, "seed \(row.seed) \(row.src)→\(row.dst) route")
            #expect(result.score == row.score, "seed \(row.seed) \(row.src)→\(row.dst) score")
            #expect(result.routeSize == row.routeSize, "seed \(row.seed) \(row.src)→\(row.dst) routeSize")
        }
    }
}
