import Foundation
import Testing
@testable import DuneIICore

/// Tests for `Simulation.StructureInfo.StructureLayout` auxiliary
/// tables (`tileDiff`, `edgeTileOffsets`). These are ports of
/// OpenDUNE's `g_table_structure_layoutTileDiff` and
/// `g_table_structure_layoutEdgeTiles` (`src/table/structureinfo.c:1261..1291`).
///
/// Used by `Pos32.targetTile` and `Pos32.distance(from:toEncoded:host:)`
/// to match OpenDUNE's `Tools_Index_GetTile` and
/// `Object_GetDistanceToEncoded` for multi-tile structure targets.
@Suite("Structure layout tables — tileDiff + edgeTileOffsets")
struct StructureLayoutTablesTests {

    typealias Layout = Simulation.StructureLayout

    @Test("tileDiff matches OpenDUNE's g_table_structure_layoutTileDiff for every layout")
    func tileDiffMatchesOpenDUNE() {
        // Verbatim from `src/table/structureinfo.c:1283..1291` — the
        // pixel offset OpenDUNE adds to a structure's stored top-left
        // position to get the layout-adjusted centre.
        let expected: [(Layout, UInt16, UInt16)] = [
            (.s1x1, 0x80, 0x80),
            (.s2x1, 0x100, 0x80),
            (.s1x2, 0x80, 0x100),
            (.s2x2, 0x100, 0x100),
            (.s2x3, 0x100, 0x180),
            (.s3x2, 0x280, 0x100),
            (.s3x3, 0x180, 0x180),
        ]
        for (layout, x, y) in expected {
            #expect(layout.tileDiff.x == x,
                    "\(layout) tileDiff.x expected \(x) got \(layout.tileDiff.x)")
            #expect(layout.tileDiff.y == y,
                    "\(layout) tileDiff.y expected \(y) got \(layout.tileDiff.y)")
        }
    }

    @Test("edgeTileOffsets matches OpenDUNE's g_table_structure_layoutEdgeTiles for every layout")
    func edgeTileOffsetsMatchOpenDUNE() {
        // Verbatim from `src/table/structureinfo.c:1261..1269` — the
        // packed-tile offset from the structure's anchor to the edge
        // tile nearest an attacker approaching from the given
        // orientation8 index (with OpenDUNE's `(orient8 + 4) & 7`
        // adjustment applied at the call site).
        let expected: [(Layout, [Int16])] = [
            (.s1x1, [0, 0,    0,     0,     0,     0,     0, 0]),
            (.s2x1, [0, 1,    1,     1,     1,     0,     0, 0]),
            (.s1x2, [0, 0,    0,  64,    64,    64,     0, 0]),
            (.s2x2, [0, 1,    1,  65,    65,    64,    64, 0]),
            (.s2x3, [0, 1,   65, 129,   129,   128,    64, 0]),
            (.s3x2, [1, 2,    2,  66,    65,    64,     0, 0]),
            (.s3x3, [1, 2,   66, 130,   129,   128,    64, 0]),
        ]
        for (layout, wanted) in expected {
            let got = layout.edgeTileOffsets
            #expect(got == wanted, "\(layout) edgeTileOffsets mismatch: got \(got), want \(wanted)")
            #expect(got.count == 8, "\(layout) must return 8 offsets")
        }
    }

    @Test("edgeTileOffsets covers all 7 enum cases")
    func edgeTileOffsetsExhaustive() {
        for layout in [Layout.s1x1, .s2x1, .s1x2, .s2x2, .s2x3, .s3x2, .s3x3] {
            // Any offset in 0..7 must be callable; no crash + 8 entries.
            let offsets = layout.edgeTileOffsets
            #expect(offsets.count == 8)
            #expect(layout.tileDiff.x > 0)
            #expect(layout.tileDiff.y > 0)
        }
    }
}
