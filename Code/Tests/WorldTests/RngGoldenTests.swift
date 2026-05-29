import Foundation
import Testing
@testable import DuneIIWorld

/// Bit-exact parity of the two RNGs against OpenDUNE. The fixture `Fixtures/rng-golden.jsonl` is the
/// committed output of `opendune --parity-golden=<path>` (the function-golden harness, OpenDUNE
/// `src/parity.c:Parity_DumpGolden`); each line is one `{fn, seed, [min, max,] out}` record. Regenerate
/// by rebuilding the patched OpenDUNE and re-running that flag — see `Documentation/Algorithms/Rng.md`.
@Suite("RNG golden parity")
struct RngGoldenTests {
    struct Record: Decodable {
        let fn: String
        let seed: UInt32
        let min: UInt16?
        let max: UInt16?
        let out: [Int]
    }

    static func records() throws -> [Record] {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.appendPathComponent("Fixtures/rng-golden.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map { try decoder.decode(Record.self, from: Data($0.utf8)) }
    }

    @Test("Tools_Random_256 reproduces every golden byte stream")
    func random256() throws {
        let records = ZRecords.random256
        #expect(!records.isEmpty)
        for record in records {
            var rng = Random256(seed: record.seed)
            for (index, expected) in record.out.enumerated() {
                let actual = rng.next()
                #expect(actual == UInt8(expected), "seed \(record.seed) draw \(index): \(actual) != \(expected)")
            }
        }
    }

    @Test("Tools_RandomLCG_Range reproduces every golden value (incl. swapped/degenerate ranges)")
    func lcgRange() throws {
        let records = ZRecords.lcgRange
        #expect(!records.isEmpty)
        for record in records {
            guard let min = record.min, let max = record.max else { Issue.record("lcg record missing min/max"); continue }

            var rng = RandomLCG(seed: UInt16(record.seed))
            for (index, expected) in record.out.enumerated() {
                let actual = rng.range(min, max)
                #expect(actual == UInt16(expected), "seed \(record.seed) [\(min),\(max)] draw \(index): \(actual) != \(expected)")
            }
        }
    }

    /// The `[0, 32767]` range is the identity scaling, so its golden stream is the raw `RandomLCG.next()`
    /// sequence — this pins the bare generator independently of the range scaling/rejection.
    @Test("RandomLCG.next matches the identity-range golden stream")
    func lcgRaw() throws {
        let record = try #require(ZRecords.lcgRange.first { $0.min == 0 && $0.max == 32767 })
        var rng = RandomLCG(seed: UInt16(record.seed))
        for expected in record.out {
            #expect(Int(rng.next()) == expected)
        }
    }

    private enum ZRecords {
        static let all = try! RngGoldenTests.records()
        static var random256: [Record] { all.filter { $0.fn == "Tools_Random_256" } }
        static var lcgRange: [Record] { all.filter { $0.fn == "Tools_RandomLCG_Range" } }
    }
}
