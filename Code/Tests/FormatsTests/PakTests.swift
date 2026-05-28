import Foundation
import Testing
@testable import DuneIIFormats

@Suite("Pak")
struct PakTests {
    // Two entries: "A" = [0x11,0x22] at offset 16, "B" = [0x33] at offset 18; 16-byte table.
    static let synthetic = Data([
        0x10, 0x00, 0x00, 0x00,   // offset of "A" = 16
        0x41, 0x00,               // "A\0"
        0x12, 0x00, 0x00, 0x00,   // offset of "B" = 18
        0x42, 0x00,               // "B\0"
        0x00, 0x00, 0x00, 0x00,   // terminating zero offset
        0x11, 0x22,               // A data (at 16)
        0x33,                     // B data (at 18)
    ])

    @Test("parses entries, offsets and sizes")
    func entries() throws {
        let archive = try Pak.Archive(PakTests.synthetic)
        #expect(archive.entries.count == 2)
        #expect(archive.entries[0] == Pak.Archive.Entry(name: "A", offset: 16, size: 2))
        #expect(archive.entries[1] == Pak.Archive.Entry(name: "B", offset: 18, size: 1))
    }

    @Test("extracts entry bytes, case-insensitively")
    func extract() throws {
        let archive = try Pak.Archive(PakTests.synthetic)
        #expect(archive.data(named: "A") == Data([ 0x11, 0x22 ]))
        #expect(archive.data(named: "b") == Data([ 0x33 ]))   // last entry runs to end-of-file
        #expect(archive.data(named: "missing") == nil)
    }

    @Test("truncated archive throws")
    func truncated() {
        #expect(throws: Pak.DecodeError.truncated) {
            _ = try Pak.Archive(Data([ 0x10, 0x00 ]))
        }
    }

    @Test("real install PAK parses and round-trips sizes")
    func realData() throws {
        guard let bytes = TestInstall.data("SCENARIO.PAK") else { return }

        let archive = try Pak.Archive(bytes)
        #expect(!archive.entries.isEmpty)
        // Every entry's extracted bytes match its declared size, and SCENARIO.PAK holds .INI scenarios.
        for entry in archive.entries {
            #expect(archive.data(entry).count == entry.size)
        }
        #expect(archive.entries.contains { $0.name.uppercased().hasSuffix(".INI") })
    }
}
