import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Pak")
struct PakTests {
    @Test("round-trip: encode then decode yields identical entries")
    func roundTripSynthetic() throws {
        let files: [(name: String, body: Data)] = [
            ("ALPHA.TXT", Data("hello".utf8)),
            ("BETA.BIN", Data([0x00, 0x01, 0x02, 0x03, 0x04])),
            ("GAMMA.DAT", Data(repeating: 0xAB, count: 257))
        ]
        let encoded = try Formats.Pak.Encoder.encode(files)
        let archive = try Formats.Pak.Archive(data: encoded)
        #expect(archive.entries.count == files.count)
        for (i, file) in files.enumerated() {
            #expect(archive.entries[i].name == file.name.uppercased())
            #expect(archive.body(for: archive.entries[i]) == file.body)
        }
    }

    @Test("lookup by name is case-insensitive")
    func caseInsensitiveLookup() throws {
        let encoded = try Formats.Pak.Encoder.encode([("TEST.DAT", Data([0x42, 0x42]))])
        let archive = try Formats.Pak.Archive(data: encoded)
        #expect(archive.body(named: "test.dat") == Data([0x42, 0x42]))
        #expect(archive.body(named: "TEST.DAT") == Data([0x42, 0x42]))
        #expect(archive.body(named: "missing.dat") == nil)
    }

    @Test("empty archive: just a terminator")
    func emptyArchive() throws {
        let encoded = Data([0x00, 0x00, 0x00, 0x00])
        let archive = try Formats.Pak.Archive(data: encoded)
        #expect(archive.entries.isEmpty)
    }

    @Test("corrupt: truncated header is rejected")
    func corruptTruncated() {
        let bad = Data([0x10, 0x00, 0x00]) // only 3 bytes
        #expect(throws: Formats.Pak.DecodeError.self) {
            _ = try Formats.Pak.Archive(data: bad)
        }
    }

    @Test("corrupt: non-monotonic offsets are rejected")
    func corruptNonMonotonic() throws {
        // Hand-build a PAK with two entries whose offsets go backwards.
        var bad = Data()
        bad.append(contentsOf: [0x20, 0x00, 0x00, 0x00]) // offset 32
        bad.append(contentsOf: Array("A.DAT".utf8)); bad.append(0)
        bad.append(contentsOf: [0x10, 0x00, 0x00, 0x00]) // offset 16 (< 32)
        bad.append(contentsOf: Array("B.DAT".utf8)); bad.append(0)
        bad.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        bad.append(Data(repeating: 0, count: 64))
        #expect(throws: Formats.Pak.DecodeError.self) {
            _ = try Formats.Pak.Archive(data: bad)
        }
    }

    @Test("corrupt: non-ASCII filename is rejected")
    func corruptNonAscii() throws {
        var bad = Data()
        bad.append(contentsOf: [0x20, 0x00, 0x00, 0x00])
        bad.append(contentsOf: [0xC3, 0xA9]) // é in UTF-8
        bad.append(0)
        bad.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        bad.append(Data(repeating: 0, count: 32))
        #expect(throws: Formats.Pak.DecodeError.self) {
            _ = try Formats.Pak.Archive(data: bad)
        }
    }

    /// Opens the real DUNE.PAK if the original install is present under
    /// `Repositories/patched_107_unofficial/`. Skipped otherwise so CI can
    /// run without the proprietary data.
    @Test("real DUNE.PAK parses and its body ranges cover the file")
    func realDunePak() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("DUNE.PAK"),
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        #expect(archive.entries.count >= 30)

        // Monotonic + non-overlapping
        for (a, b) in zip(archive.entries, archive.entries.dropFirst()) {
            #expect(a.range.upperBound == b.range.lowerBound)
        }
        // All names look like 8.3 uppercase ASCII and contain a dot.
        for entry in archive.entries {
            #expect(entry.name.allSatisfy { $0.isASCII })
            #expect(entry.name == entry.name.uppercased())
            #expect(entry.name.contains("."))
        }
    }

}
