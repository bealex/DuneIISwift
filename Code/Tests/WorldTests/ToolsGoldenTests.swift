import Foundation
import Testing

@testable import DuneIIWorld

/// Bit-exact parity of the misc `Tools_*` primitives against OpenDUNE, from the per-category golden
/// fixtures (see `GoldenFixture`).
@Suite("Tools golden parity")
struct ToolsGoldenTests {
    @Test("Tools_AdjustToGameSpeed over every game speed / inverse / case")
    func adjustToGameSpeed() {
        let records = GoldenFixture.records("gamespeed-golden.jsonl", fn: "Tools_AdjustToGameSpeed")
        #expect(!records.isEmpty)
        for record in records {
            let actual = Tools.adjustToGameSpeed(
                normal: record.normal!,
                minimum: record.min!,
                maximum: record.max!,
                inverseSpeed: record.inverse! != 0,
                gameSpeed: record.gameSpeed!
            )
            #expect(
                Int(actual) == record.out.scalar,
                "speed \(record.gameSpeed!) inv \(record.inverse!) n=\(record.normal!) [\(record.min!),\(record.max!)]"
            )
        }
    }

    @Test("Tools_Index_GetType")
    func indexType() {
        let records = GoldenFixture.records("index-golden.jsonl", fn: "Tools_Index_GetType")
        #expect(!records.isEmpty)
        for record in records {
            #expect(Tools.indexType(record.encoded!).rawValue == record.out.scalar, "encoded \(record.encoded!)")
        }
    }

    @Test("Tools_Index_Decode")
    func indexDecode() {
        let records = GoldenFixture.records("index-golden.jsonl", fn: "Tools_Index_Decode")
        #expect(!records.isEmpty)
        for record in records {
            #expect(Int(Tools.indexDecode(record.encoded!)) == record.out.scalar, "encoded \(record.encoded!)")
        }
    }
}
