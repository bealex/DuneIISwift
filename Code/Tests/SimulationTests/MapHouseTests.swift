import Foundation
import Testing
@testable import DuneIISimulation

/// Golden parity for the Tier-D/E primitives that are dependency-ready: `Map_IsValidPosition` and
/// `House_AreAllied`, from `maphouse-golden.jsonl` (dumped per map scale / player house). The rest of
/// Tiers D/E is blocked on the sprite/scenario init + Tier-F lifecycle (Plan §9).
@Suite("Map / House primitives golden parity")
struct MapHouseTests {
    struct Row: Decodable {
        let fn: String
        let position: UInt16?
        let mapScale: UInt8?
        let playerHouseID: UInt8?
        let h1: UInt8?
        let h2: UInt8?
        let out: Int
    }

    /// The oracle fixtures live under `WorldTests/Fixtures/` (one `--parity-golden` run); load the
    /// shared file from this sibling test target.
    static func rows(_ fn: String) -> [Row] {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()                 // .../Tests/SimulationTests/
        url.deleteLastPathComponent()                 // .../Tests/
        url.appendPathComponent("WorldTests/Fixtures/maphouse-golden.jsonl")
        let text = try! String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return text.split(separator: "\n")
            .map { try! decoder.decode(Row.self, from: Data($0.utf8)) }
            .filter { $0.fn == fn }
    }

    @Test("Map_IsValidPosition over positions × map scale")
    func mapIsValidPosition() {
        let p: any MapPrimitives = DefaultMapPrimitives()
        let records = Self.rows("Map_IsValidPosition")
        #expect(records.count == 30)
        for r in records {
            #expect(p.isValidPosition(r.position!, mapScale: r.mapScale!) == (r.out != 0),
                    "position \(r.position!) scale \(r.mapScale!)")
        }
    }

    @Test("House_AreAllied over house pairs × player house")
    func houseAreAllied() {
        let p: any HousePrimitives = DefaultHousePrimitives()
        let records = Self.rows("House_AreAllied")
        #expect(records.count == 147)
        for r in records {
            #expect(p.areAllied(r.h1!, r.h2!, playerHouseID: r.playerHouseID!) == (r.out != 0),
                    "h1 \(r.h1!) h2 \(r.h2!) player \(r.playerHouseID!)")
        }
    }
}
