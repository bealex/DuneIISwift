import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Save.Container")
struct SaveTests {
    // MARK: Synthetic

    @Test("synthetic FORM/SCEN with two chunks round-trips tag set and bodies")
    func syntheticTwoChunks() throws {
        let infoBody = Data([0x90, 0x02, 0x11, 0x22]) // version 0x0290 LE + payload
        let nameBody = Data("Tleilaxu\0".utf8)        // 9 bytes → odd, pad byte required
        #expect(nameBody.count % 2 == 1)

        let form = makeScenForm(chunks: [
            ("NAME", nameBody),
            ("INFO", infoBody)
        ])
        let container = try Formats.Save.Container.decode(form)

        #expect(Set(container.tags) == ["NAME", "INFO"])
        #expect(container.chunk(named: "INFO") == infoBody)
        #expect(container.chunk(named: "NAME") == nameBody)
        #expect(container.version == 0x0290)
    }

    @Test("MAP tag with trailing space is preserved as a distinct key")
    func mapTagWithSpace() throws {
        let form = makeScenForm(chunks: [
            ("INFO", Data([0x90, 0x02])),
            ("MAP ", Data([0xAA, 0xBB]))
        ])
        let container = try Formats.Save.Container.decode(form)
        #expect(container.chunk(named: "MAP ") == Data([0xAA, 0xBB]))
        #expect(container.chunk(named: "MAP") == nil)
    }

    @Test("odd-length chunk is followed by a pad byte, next chunk starts aligned")
    func padByteHandling() throws {
        let first = Data([0x01, 0x02, 0x03])        // 3 bytes → pad to 4
        let second = Data([0xDE, 0xAD, 0xBE, 0xEF]) // 4 bytes, aligned
        let form = makeScenForm(chunks: [
            ("AAAA", first),
            ("BBBB", second)
        ])
        let container = try Formats.Save.Container.decode(form)
        #expect(container.chunk(named: "AAAA") == first)
        #expect(container.chunk(named: "BBBB") == second)
    }

    // MARK: Failure modes

    @Test("non-FORM magic is rejected")
    func nonForm() {
        var data = Data("NOPE".utf8)
        data.append(uint32BE: 4)
        data.append(contentsOf: "SCEN".utf8)
        #expect(throws: Formats.Save.Container.DecodeError.notForm) {
            _ = try Formats.Save.Container.decode(data)
        }
    }

    @Test("wrong inner form type is rejected")
    func wrongInnerTag() {
        var data = Data("FORM".utf8)
        data.append(uint32BE: 4)
        data.append(contentsOf: "XXXX".utf8)
        #expect(throws: Formats.Save.Container.DecodeError.notScen) {
            _ = try Formats.Save.Container.decode(data)
        }
    }

    @Test("chunk length past end-of-file is rejected")
    func chunkPastEOF() {
        var data = Data("FORM".utf8)
        data.append(uint32BE: 16)
        data.append(contentsOf: "SCEN".utf8)
        data.append(contentsOf: "INFO".utf8)
        data.append(uint32BE: 999) // oversized length
        data.append(contentsOf: [0x90, 0x02])
        #expect(throws: Formats.Save.Container.DecodeError.self) {
            _ = try Formats.Save.Container.decode(data)
        }
    }

    @Test("truncated header (less than 12 bytes) is rejected")
    func truncatedHeader() {
        let data = Data("FORM".utf8) // 4 bytes only
        #expect(throws: Formats.Save.Container.DecodeError.self) {
            _ = try Formats.Save.Container.decode(data)
        }
    }

    // MARK: Real data

    @Test("_SAVE001.DAT from the install decodes into the documented chunk set")
    func realSave001() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("_SAVE001.DAT"),
              FileManager.default.fileExists(atPath: url.path) else { return }

        let data = try Data(contentsOf: url)
        let container = try Formats.Save.Container.decode(data)

        // The original Dune II 1.07 engine writes exactly these six chunks.
        // `TEAM` is only emitted when an AI team is defined in the scenario,
        // and `ODUN` is an OpenDUNE-only extension — neither appears in the
        // vanilla `_SAVE00?.DAT` files that ship with patched_107.
        let expected: Set<String> = ["NAME", "INFO", "PLYR", "UNIT", "BLDG", "MAP "]
        #expect(Set(container.tags).isSuperset(of: expected))
        #expect(container.version == 0x0290)

        // Every body's range must lie inside the file.
        for tag in container.tags {
            let body = container.chunk(named: tag)!
            #expect(body.count >= 0)
            #expect(body.count <= data.count)
        }
    }
}

// MARK: - Helpers

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
    mutating func append(uint32BE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
