import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIISimulation

/// Golden parity for `Unit_GetTileEnterScore`: generate a map from a seed (no units/structures placed)
/// and score entering several tiles from both an orthogonal and a diagonal direction, for every unit
/// type, against the oracle (`Golden_TileEnterScore` → `tileenterscore-golden.jsonl`, mapScale 0,
/// player Harkonnen, `g_dune2_enhanced` pinned false = the 1.07 path). This exercises the map-validity
/// gate + the landscape movement-speed scoring; the occupant/structure branches are covered in
/// `UnitMovementDecisionTests`.
@Suite("Unit_GetTileEnterScore golden parity")
struct TileEnterScoreGoldenTests {
    struct Row: Decodable {
        let seed: UInt32; let type: UInt8; let packed: UInt16; let orient8: UInt16; let score: Int16
    }

    @Test("tileEnterScore matches the oracle for every type / tile / direction")
    func tileEnterScore() throws {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }  // Code/Tests/SimulationTests/ → repo root
        let iconMap = try IconMap(Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        let fixture = repo.appendingPathComponent("Code/Tests/WorldTests/Fixtures/tileenterscore-golden.jsonl")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        let rows = text.split(separator: "\n").map { try! JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        #expect(!rows.isEmpty)

        let unitPrim: any UnitPrimitives = DefaultUnitPrimitives()
        let mapPrim: any MapPrimitives = DefaultMapPrimitives()
        let housePrim: any HousePrimitives = DefaultHousePrimitives()
        // The generated landscape depends only on the seed, so cache one GameState per seed.
        var bySeed: [UInt32: GameState] = [:]
        for row in rows {
            let state =
                bySeed[row.seed]
                ?? {
                    var s = GameState()
                    s.tileIDs = TileIDs(iconMap: iconMap) ?? TileIDs()
                    s.createLandscape(seed: row.seed, iconMap: iconMap)
                    bySeed[row.seed] = s
                    return s
                }()
            var unit = Unit()  // zero-arg init resolves to DuneIIWorld.Unit (not Foundation.Unit)
            unit.o.index = 0
            unit.o.type = row.type
            unit.o.houseID = UInt8(HouseID.harkonnen.rawValue)
            unit.targetMove = 0
            let score = unitPrim.tileEnterScore(
                unit,
                packed: row.packed,
                orient8: row.orient8,
                in: state,
                map: mapPrim,
                house: housePrim
            )
            #expect(
                score == row.score,
                "seed \(row.seed) type \(row.type) packed \(row.packed) orient \(row.orient8)"
            )
        }
    }
}
