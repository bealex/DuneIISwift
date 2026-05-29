import Foundation

/// Shared loader for the OpenDUNE function-golden fixtures (`opendune --parity-golden=<dir>`), one
/// per category under `Fixtures/` (`rng-golden.jsonl`, `tile-golden.jsonl`, …). One JSON object per
/// line; fields are a superset across every dumped primitive, so all but `fn`/`out` are optional.
/// Regenerate by rebuilding the patched OpenDUNE and re-running the flag — see
/// `Documentation/Architecture/FunctionParityHarness.md`.
enum GoldenFixture {
    struct Record: Decodable {
        let fn: String
        let seed: UInt32?
        let min: UInt16?
        let max: UInt16?
        let from: IntList?
        let to: IntList?
        let packed: UInt16?
        let out: IntList
    }

    /// A JSON field that is either a scalar integer or an array of integers (e.g. `out` is a count for
    /// distances but a `[x, y]` pair for `Tile_UnpackTile`).
    struct IntList: Decodable {
        let values: [Int]
        var scalar: Int { values[0] }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let scalar = try? container.decode(Int.self) {
                values = [scalar]
            } else {
                values = try container.decode([Int].self)
            }
        }
    }

    /// All records in the category fixture `file` (e.g. `"rng-golden.jsonl"`), filtered to `fn`.
    static func records(_ file: String, fn: String) -> [Record] {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.appendPathComponent("Fixtures/\(file)")
        let text = try! String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return text.split(separator: "\n")
            .map { try! decoder.decode(Record.self, from: Data($0.utf8)) }
            .filter { $0.fn == fn }
    }
}
