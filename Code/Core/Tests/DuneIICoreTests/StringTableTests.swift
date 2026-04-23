import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Strings — ENG decoder (plain + compressed)")
struct StringTableTests {

    @Test("Plain decoder: round-trips a two-string file")
    func plainRoundTrip() throws {
        // Layout: offset table (uint16 LE × count), then NUL-terminated
        // strings. OpenDUNE reads `firstOffset / 2` as the count, so
        // offset[0] must point past the whole table.
        let str1 = "Hello"
        let str2 = "World"
        var body = Data()
        // Table of 2 offsets (each uint16 LE) → table length 4.
        let off1: UInt16 = 4
        let off2: UInt16 = UInt16(4 + str1.utf8.count + 1)
        body.append(contentsOf: [UInt8(off1 & 0xFF), UInt8(off1 >> 8)])
        body.append(contentsOf: [UInt8(off2 & 0xFF), UInt8(off2 >> 8)])
        body.append(contentsOf: str1.utf8); body.append(0)
        body.append(contentsOf: str2.utf8); body.append(0)

        let out = try Formats.Strings.decode(body, compressed: false)
        #expect(out == ["Hello", "World"])
    }

    @Test("Compressed decoder: packed pair 0x80 expands to couples[0]+couples[16] = ' t'")
    func compressedPackedPair() {
        // c = 0x80 → masked = 0, first = couples[0] = ' ', second = couples[16] = 't'
        let decoded = Formats.Strings.decompress(Data([0x80]))
        #expect(decoded == " t")
    }

    @Test("Compressed decoder: 0x1B escape introduces extended byte")
    func compressedEscape() {
        // 0x1B 0x05 → output 0x7F + 0x05 = 0x84
        let decoded = Formats.Strings.decompress(Data([0x1B, 0x05]))
        #expect(decoded.unicodeScalars.first?.value == 0x84)
    }

    @Test("Compressed decoder: unpacked ASCII passes through")
    func compressedLiteral() {
        let decoded = Formats.Strings.decompress(Data("Hi!".utf8))
        #expect(decoded == "Hi!")
    }

    @Test("Compressed decoder: truncated 0x1B at end-of-input is dropped")
    func compressedTruncatedEscape() {
        // Lone 0x1B with no follow-up byte: drop, don't crash.
        let decoded = Formats.Strings.decompress(Data([0x41, 0x1B]))
        #expect(decoded == "A")
    }

    @Test("Compressed decoder produces a recognisable English word from a known packed byte")
    func compressedKnownWord() {
        // `couples` table rows (offset 16, 8 chars each, indexed by
        // top-nibble of the compressed byte):
        //   row 0 (top nibble 0, " ?"): "tasio wb"
        //   row 1 (top nibble 1, "e?"): " rnsdalm"
        //   row 2 (top nibble 2, "t?"): "h ieoras"
        //
        // Pack 0x81 → masked=0x01, first = couples[0>>3=0] = ' ',
        //             second = couples[16+1] = couples[17] = 'a'.
        // So 0x81 → " a".
        let decoded = Formats.Strings.decompress(Data([0x81]))
        #expect(decoded == " a")
    }

    @Test("Truncated header raises DecodeError.truncatedHeader")
    func truncatedHeaderError() {
        #expect(throws: Formats.Strings.DecodeError.truncatedHeader) {
            _ = try Formats.Strings.decode(Data([0x42]), compressed: false)
        }
    }

    @Test("Invalid offset raises DecodeError.invalidOffset")
    func invalidOffsetError() {
        // Two entries, but the second offset points past EOF.
        var body = Data()
        body.append(contentsOf: [0x04, 0x00])   // offset 0 = 4
        body.append(contentsOf: [0xFF, 0x00])   // offset 1 = 255 (past EOF)
        body.append(contentsOf: "hi".utf8); body.append(0)
        #expect {
            _ = try Formats.Strings.decode(body, compressed: false)
        } throws: { error in
            guard case Formats.Strings.DecodeError.invalidOffset = error else {
                return false
            }
            return true
        }
    }

    // MARK: - Real TEXTA.ENG (Atreides briefings)

    @Test("Real TEXTA.ENG decodes into 40 strings with recognisable English")
    func realTextaEng() throws {
        guard let url = TestInstall.locate()?
            .appendingPathComponent("ENGLISH.PAK"),
            FileManager.default.fileExists(atPath: url.path)
        else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let body = archive.body(named: "TEXTA.ENG") else { return }
        let strings = try Formats.Strings.decode(body, compressed: true)
        // TEXTA.ENG carries the 40 Atreides campaign strings.
        // Loose upper-bound check — it may include a trailing blank slot.
        #expect(strings.count >= 30 && strings.count <= 45,
                "TEXTA.ENG string count outside plausible range: \(strings.count)")
        // Spot-check: the very first Atreides briefing opens with the
        // house backdrop ("House Atreides / Caladan / …"). Search any
        // of the first ~6 strings for the word "Atreides" — the
        // decoder is doing its job if at least one hits.
        let head = strings.prefix(6).joined(separator: " ").lowercased()
        #expect(head.contains("atreides"),
                "Atreides string-table decode broken; head = \"\(head.prefix(200))\"")
    }
}
