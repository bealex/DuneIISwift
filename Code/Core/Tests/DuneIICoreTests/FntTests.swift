import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Fnt")
struct FntTests {
    @Test("wrong magic is rejected")
    func badMagic() {
        var data = Data(count: 32)
        data[2] = 0x12 // not 0x00
        data[3] = 0x34
        #expect(throws: Formats.Fnt.DecodeError.self) {
            _ = try Formats.Fnt.decode(data)
        }
    }

    @Test("real NEW8P.FNT has a printable 'A'")
    func realNew8p() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("DUNE.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let data = archive.body(named: "NEW8P.FNT") else { return }
        let font = try Formats.Fnt.decode(data)
        #expect(font.height > 0)
        #expect(font.glyphs.count >= 128)
        if let a = font[Character("A")] {
            #expect(a.width > 0)
            #expect(a.usedLines > 0)
            #expect(a.pixels.count == a.width * a.usedLines)
            // 'A' must have at least one non-zero (non-transparent) pixel.
            #expect(a.pixels.contains { $0 != 0 })
        } else {
            Issue.record("'A' glyph missing from NEW8P.FNT")
        }
    }
}
