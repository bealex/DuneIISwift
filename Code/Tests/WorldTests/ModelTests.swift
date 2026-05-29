import Foundation
import Testing
@testable import DuneIIWorld

/// Tests for the runtime data-model PODs. The bitfield layouts (`ObjectFlags`, `MapTile`) are golden-
/// pinned against the OpenDUNE oracle — they round-trip through the packed integer in the save format,
/// so the bit positions must match exactly. The rest is default-construction / round-trip sanity (the
/// PODs' full verification is the later save-format round-trip).
@Suite("Data-model PODs")
struct ModelTests {
    struct FlagRow: Decodable { let flag: String; let mask: UInt32 }
    struct TileRow: Decodable { let field: String; let value: UInt32; let packed: UInt32 }

    @Test("ObjectFlags bit layout matches the oracle")
    func objectFlags() throws {
        let members: [String: ObjectFlags] = [
            "used": .used, "allocated": .allocated, "isNotOnMap": .isNotOnMap, "isSmoking": .isSmoking,
            "fireTwiceFlip": .fireTwiceFlip, "animationFlip": .animationFlip, "bulletIsBig": .bulletIsBig,
            "isWobbling": .isWobbling, "inTransport": .inTransport, "byScenario": .byScenario,
            "degrades": .degrades, "isHighlighted": .isHighlighted, "isDirty": .isDirty,
            "repairing": .repairing, "onHold": .onHold, "isUnit": .isUnit, "upgrading": .upgrading,
        ]
        let rows = GoldenFixture.decode("objectflags-golden.jsonl", as: FlagRow.self)
        #expect(rows.count == members.count)
        for row in rows {
            let member = try #require(members[row.flag])
            #expect(member.rawValue == row.mask)
        }
    }

    @Test("MapTile bit layout matches the oracle, and packs round-trip")
    func mapTile() {
        let rows = GoldenFixture.decode("maptile-golden.jsonl", as: TileRow.self)
        #expect(rows.count == 9)
        for row in rows {
            var t = MapTile()
            switch row.field {
            case "groundTileID":  t.groundTileID = UInt16(row.value)
            case "overlayTileID": t.overlayTileID = UInt8(row.value)
            case "houseID":       t.houseID = UInt8(row.value)
            case "isUnveiled":    t.isUnveiled = row.value != 0
            case "hasUnit":       t.hasUnit = row.value != 0
            case "hasStructure":  t.hasStructure = row.value != 0
            case "hasAnimation":  t.hasAnimation = row.value != 0
            case "hasExplosion":  t.hasExplosion = row.value != 0
            case "index":         t.index = UInt8(row.value)
            default:              Issue.record("unknown Tile field \(row.field)")
            }
            #expect(t.packed == row.packed)
            #expect(MapTile(packed: row.packed) == t)              // unpack(pack) == identity
            #expect(MapTile(packed: row.packed).packed == row.packed)
        }
    }

    @Test("PODs default-construct to OpenDUNE-faithful zero state")
    func defaults() {
        let o = Object()
        #expect(o.flags == [])
        #expect(o.linkedID == 0xFF)
        #expect(o.position == Tile32(x: 0, y: 0))
        #expect(o.script.variables.count == 5)
        #expect(o.script.stack.count == 15)

        let u = Unit()
        #expect(u.orientation.count == 2)
        #expect(u.route.count == 14)
        #expect(u.o.flags == [])

        let s = Structure()
        #expect(s.state == .idle)

        let h = House()
        #expect(h.flags == [])
        #expect(h.starportLinkedID == 0xFFFF)
        #expect(h.aiStructureRebuild.count == 5)
        #expect(h.aiStructureRebuild.allSatisfy { $0.count == 2 })

        let t = Team()
        #expect(t.flags == [])
        #expect(t.script.stack.count == 15)
    }

    @Test("flag OptionSets set / contain / clear")
    func flagOps() {
        var o = Object()
        o.flags.insert(.used)
        o.flags.insert(.isUnit)
        #expect(o.flags.contains(.used))
        #expect(o.flags.contains(.isUnit))
        #expect(!o.flags.contains(.allocated))
        o.flags.remove(.used)
        #expect(!o.flags.contains(.used))
        #expect(o.flags.contains(.isUnit))

        var h = House()
        h.flags = [.used, .human]
        #expect(h.flags.contains(.human))
        #expect(!h.flags.contains(.isAIActive))
    }
}
