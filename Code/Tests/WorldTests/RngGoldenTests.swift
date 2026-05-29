import Foundation
import Testing
@testable import DuneIIWorld

/// Bit-exact parity of the two RNGs against OpenDUNE, from the shared golden fixture (see
/// `GoldenFixture`). Records: `Tools_Random_256` (`seed`, 256-byte `out`) and `Tools_RandomLCG_Range`
/// (`seed`, `min`, `max`, 64-value `out`).
@Suite("RNG golden parity")
struct RngGoldenTests {
    @Test("Tools_Random_256 reproduces every golden byte stream")
    func random256() {
        let records = GoldenFixture.records("Tools_Random_256")
        #expect(!records.isEmpty)
        for record in records {
            var rng = Random256(seed: record.seed!)
            for (index, expected) in record.out.values.enumerated() {
                let actual = rng.next()
                #expect(actual == UInt8(expected), "seed \(record.seed!) draw \(index): \(actual) != \(expected)")
            }
        }
    }

    @Test("Tools_RandomLCG_Range reproduces every golden value (incl. swapped/degenerate ranges)")
    func lcgRange() {
        let records = GoldenFixture.records("Tools_RandomLCG_Range")
        #expect(!records.isEmpty)
        for record in records {
            var rng = RandomLCG(seed: UInt16(record.seed!))
            for (index, expected) in record.out.values.enumerated() {
                let actual = rng.range(record.min!, record.max!)
                #expect(actual == UInt16(expected), "seed \(record.seed!) [\(record.min!),\(record.max!)] draw \(index): \(actual) != \(expected)")
            }
        }
    }

    /// The `[0, 32767]` range is the identity scaling, so its golden stream is the raw `RandomLCG.next()`
    /// sequence — this pins the bare generator independently of the range scaling/rejection.
    @Test("RandomLCG.next matches the identity-range golden stream")
    func lcgRaw() throws {
        let record = try #require(GoldenFixture.records("Tools_RandomLCG_Range").first { $0.min == 0 && $0.max == 32767 })
        var rng = RandomLCG(seed: UInt16(record.seed!))
        for expected in record.out.values {
            #expect(Int(rng.next()) == expected)
        }
    }
}
