import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Save.Game")
struct SaveGameTests {
    // MARK: Real data — end-to-end

    @Test("_SAVE001.DAT decodes end-to-end with every required chunk populated")
    func realSave001EndToEnd() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("_SAVE001.DAT"),
              FileManager.default.fileExists(atPath: url.path) else { return }

        let data = try Data(contentsOf: url)
        let game = try Formats.Save.Game.decode(data)

        // NAME is human-readable, non-empty.
        #expect(!game.description.isEmpty)

        // INFO version must be modern.
        #expect(game.info.version == 0x0290)
        #expect((1...22).contains(game.info.scenarioID))

        // PLYR must have at least one human slot.
        #expect(game.houses.humanSlot != nil)
        #expect(!game.houses.slots.isEmpty)

        // UNIT + BLDG must be non-empty rosters.
        #expect(!game.units.slots.isEmpty)
        #expect(!game.structures.slots.isEmpty)

        // MAP chunk must carry a sparse override set.
        #expect(!game.tileMap.entries.isEmpty)
        #expect(game.tileMap.entries.count <= 4096)

        // Vanilla 1.07 emits neither TEAM nor ODUN.
        #expect(game.team == nil)
        #expect(game.unitsNew == nil)
    }

    // MARK: Synthetic — cross-chunk composition

    @Test("synthetic minimal-valid save round-trips NAME through every required chunk")
    func syntheticMinimalComposition() throws {
        // Construct a valid FORM with exactly the six required chunks, all minimal.
        let name = Data("Tleilaxu\0".utf8)
        let info = makeMinimalInfoBody()
        let plyr = makeMinimalHouseRecord(houseID: 2, human: true)
        let unit = makeMinimalUnitRecord(index: 0, type: 0, houseID: 2)
        let bldg = makeMinimalStructureRecord(index: 0, type: 0, houseID: 2)
        // One sparse tile at cell 100, marked unveiled.
        var mapBody = Data()
        mapBody.append(uint16LE: 100)
        mapBody.append(0x01); mapBody.append(0x00); mapBody.append(0x08); mapBody.append(0x00)

        let form = makeScenForm(chunks: [
            ("NAME", name),
            ("INFO", info),
            ("PLYR", plyr),
            ("UNIT", unit),
            ("BLDG", bldg),
            ("MAP ", mapBody)
        ])

        let game = try Formats.Save.Game.decode(form)
        #expect(game.description == "Tleilaxu")
        #expect(game.info.version == 0x0290)
        #expect(game.houses.slots.count == 1)
        #expect(game.houses.humanSlot?.index == 2)
        #expect(game.units.slots.count == 1)
        #expect(game.structures.slots.count == 1)
        #expect(game.tileMap.entries.count == 1)
        #expect(game.tileMap.entries[0].cellIndex == 100)
        #expect(game.tileMap.entries[0].tile.isUnveiled)
    }

    // MARK: Failure modes

    @Test("missing required chunk surfaces the specific tag")
    func missingRequiredChunk() {
        let form = makeScenForm(chunks: [
            ("NAME", Data("X\0".utf8)),
            ("INFO", makeMinimalInfoBody()),
            ("PLYR", makeMinimalHouseRecord(houseID: 0, human: true)),
            // UNIT missing
            ("BLDG", makeMinimalStructureRecord(index: 0, type: 0, houseID: 0)),
            ("MAP ", Data())
        ])
        #expect(throws: Formats.Save.Game.DecodeError.missingRequiredChunk(tag: "UNIT")) {
            _ = try Formats.Save.Game.decode(form)
        }
    }

    @Test("malformed container propagates a .container error")
    func malformedContainer() {
        var bad = Data("NOPE".utf8)
        bad.append(uint32BE: 4)
        bad.append(contentsOf: "SCEN".utf8)
        #expect(throws: Formats.Save.Game.DecodeError.self) {
            _ = try Formats.Save.Game.decode(bad)
        }
        do {
            _ = try Formats.Save.Game.decode(bad)
            Issue.record("expected .container error")
        } catch Formats.Save.Game.DecodeError.container {
            // expected
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("non-ASCII NAME chunk is rejected")
    func nonAsciiName() {
        var name = Data([0x41, 0x42]) // "AB"
        name.append(0xFF)              // high bit → non-ASCII
        name.append(0)                 // NUL
        let form = makeScenForm(chunks: [
            ("NAME", name),
            ("INFO", makeMinimalInfoBody()),
            ("PLYR", makeMinimalHouseRecord(houseID: 0, human: true)),
            ("UNIT", Data()),
            ("BLDG", Data()),
            ("MAP ", Data())
        ])
        #expect(throws: Formats.Save.Game.DecodeError.nameNotAscii) {
            _ = try Formats.Save.Game.decode(form)
        }
    }

    @Test("legacy version in INFO surfaces .info with legacyVersion")
    func legacyVersionPropagates() {
        var legacyInfo = makeMinimalInfoBody()
        legacyInfo[0] = 0x00
        legacyInfo[1] = 0x00
        let form = makeScenForm(chunks: [
            ("NAME", Data("x\0".utf8)),
            ("INFO", legacyInfo),
            ("PLYR", makeMinimalHouseRecord(houseID: 0, human: true)),
            ("UNIT", Data()),
            ("BLDG", Data()),
            ("MAP ", Data())
        ])
        do {
            _ = try Formats.Save.Game.decode(form)
            Issue.record("expected .info(legacyVersion) error")
        } catch let Formats.Save.Game.DecodeError.info(underlying) {
            if case .legacyVersion = underlying { /* ok */ }
            else { Issue.record("wrong underlying: \(underlying)") }
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("unknown chunks are tolerated, required chunks still decode")
    func unknownChunksIgnored() throws {
        let form = makeScenForm(chunks: [
            ("NAME", Data("x\0".utf8)),
            ("NICE", Data([0xCA, 0xFE, 0xBA, 0xBE])), // unknown tag, even length
            ("INFO", makeMinimalInfoBody()),
            ("PLYR", makeMinimalHouseRecord(houseID: 0, human: true)),
            ("UNIT", Data()),
            ("BLDG", Data()),
            ("MAP ", Data()),
            ("XTRA", Data([0x00])) // unknown, odd length → container adds pad
        ])
        let game = try Formats.Save.Game.decode(form)
        #expect(game.description == "x")
    }
}

// MARK: - Helpers

private func makeMinimalInfoBody() -> Data {
    var body = Data()
    body.append(uint16LE: 0x0290) // version
    body.append(Data(count: 328)) // full payload zeroed
    precondition(body.count == 330)
    return body
}

private func makeMinimalHouseRecord(houseID: UInt16, human: Bool) -> Data {
    var d = Data()
    d.append(uint16LE: houseID)                           // 0 index
    d.append(uint16LE: 0)                                 // 2 harvestersIncoming
    d.append(uint16LE: human ? 0x01 | 0x02 : 0x01)        // 4 flags
    for _ in 0..<4 { d.append(uint16LE: 0) }              // 6..14 unit counters
    d.append(uint32LE: 0)                                 // 14 structuresBuilt
    for _ in 0..<6 { d.append(uint16LE: 0) }              // 18..30 economy
    d.append(uint16LE: 0)                                 // 30 palace.x
    d.append(uint16LE: 0)                                 // 32 palace.y
    d.append(uint16LE: 0)                                 // 34 pad
    for _ in 0..<3 { d.append(uint16LE: 0) }              // 36..42 timers
    d.append(uint16LE: 0)                                 // 42 starportTimeLeft
    d.append(uint16LE: 0xFFFF)                            // 44 starportLinkedID
    for _ in 0..<10 { d.append(uint16LE: 0) }             // 46..66 aiStructureRebuild
    precondition(d.count == 66)
    return d
}

private func makeMinimalUnitRecord(index: UInt16, type: UInt8, houseID: UInt8) -> Data {
    var d = Data()
    // Object header (71 bytes): minimal — used + isUnit flags.
    d.append(uint16LE: index)                             // 0
    d.append(type)                                        // 2
    d.append(0xFF)                                        // 3 linkedID
    d.append(uint32LE: 0x01 | 0x010000)                   // 4 flags: used | isUnit
    d.append(houseID)                                     // 8
    d.append(0)                                           // 9 seenByHouses
    d.append(uint16LE: 0); d.append(uint16LE: 0)          // 10-14 position
    d.append(uint16LE: 1)                                 // 14 hitpoints
    d.append(Data(count: 55))                             // 16-71 ScriptState zeroed
    // Unit tail (57 bytes) — all zero.
    d.append(Data(count: 57))
    precondition(d.count == 128)
    return d
}

private func makeMinimalStructureRecord(index: UInt16, type: UInt8, houseID: UInt8) -> Data {
    var d = Data()
    d.append(uint16LE: index)
    d.append(type)
    d.append(0xFF)
    d.append(uint32LE: 0x01)  // used, isUnit clear
    d.append(houseID)
    d.append(0)
    d.append(uint16LE: 0); d.append(uint16LE: 0)
    d.append(uint16LE: 1)
    d.append(Data(count: 55))
    d.append(Data(count: 17)) // structure tail
    precondition(d.count == 88)
    return d
}

private func makeScenForm(chunks: [(String, Data)]) -> Data {
    var body = Data()
    body.append(contentsOf: "SCEN".utf8)
    for (tag, chunk) in chunks {
        precondition(tag.utf8.count == 4)
        body.append(contentsOf: tag.utf8)
        body.append(uint32BE: UInt32(chunk.count))
        body.append(chunk)
        if chunk.count % 2 != 0 { body.append(0) }
    }
    var out = Data("FORM".utf8)
    out.append(uint32BE: UInt32(body.count))
    out.append(body)
    return out
}

private extension Data {
    mutating func append(uint16LE value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func append(uint32LE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
    mutating func append(uint32BE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
