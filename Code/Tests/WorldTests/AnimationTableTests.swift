import Foundation
import Testing

@testable import DuneIIWorld

/// `AnimationTables.structure` matches the oracle's `g_table_animation_structure` (the Swift rows are
/// trimmed of the trailing `STOP`/`[0,0]` padding; the fixture keeps all 16 columns).
@Suite("Animation table golden parity")
struct AnimationTableTests {
    struct Row: Decodable { let index: Int; let cmds: [[Int]] }

    @Test("g_table_animation_structure matches")
    func structureTable() {
        let rows = GoldenFixture.decode("animationstructure-golden.jsonl", as: Row.self)
        #expect(rows.count == 29)
        for row in rows {
            let mine = AnimationTables.structure[row.index]
            #expect(mine.count <= 16)
            for (i, command) in mine.enumerated() {
                #expect(Int(command.command.rawValue) == row.cmds[i][0], "row \(row.index) cmd \(i)")
                #expect(Int(command.parameter) == row.cmds[i][1], "row \(row.index) param \(i)")
            }
            for i in mine.count ..< 16 { #expect(row.cmds[i] == [ 0, 0 ], "row \(row.index) padding \(i)") }
        }
    }
}
