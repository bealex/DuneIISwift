import Foundation
import Testing
@testable import DuneIIWorld

/// CHOAM starport-price parity against OpenDUNE's `GUI_FactoryWindow_CalculateStarportPrice` (`gui.c:2726`).
/// The `choamprice-golden.jsonl` fixture (from `opendune --parity-golden=<dir>`) holds, per seed, the price
/// the oracle rolls for each base cost; `GameState.starportPrice` must reproduce it value-for-value — proving
/// the formula and its two `RandomLCG` draws per item align. See `Documentation/Algorithms/StarportPrice.md`.
@Suite("Starport CHOAM price golden")
struct StarportPriceTests {
    struct Rec: Decodable { let seed: UInt16; let costs: [UInt16]; let out: [UInt16] }

    @Test("starportPrice reproduces the oracle's CHOAM price for every seed × cost")
    func prices() {
        let records: [Rec] = GoldenFixture.decode("choamprice-golden.jsonl")
        #expect(!records.isEmpty)
        for r in records {
            var s = GameState()
            s.randomLCG = RandomLCG(seed: r.seed)
            for (i, cost) in r.costs.enumerated() {
                let actual = s.starportPrice(buildCredits: cost)
                #expect(actual == r.out[i], "seed \(r.seed) cost \(cost): \(actual) != \(r.out[i])")
            }
        }
    }
}
