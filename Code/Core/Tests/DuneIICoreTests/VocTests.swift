import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Voc")
struct VocTests {
    @Test("synthetic minimal VOC decodes to expected samples and rate")
    func synthetic() throws {
        let magic = Array("Creative Voice File\u{1A}".utf8)
        // rateDivisor = 131 → sampleRate = 1_000_000 / (256 - 131) = 1_000_000/125 = 8000
        let samples: [UInt8] = [10, 20, 30, 40]
        let blockBody: [UInt8] = [131, 0] + samples // rateDivisor, codec, samples
        var file = Data()
        file.append(contentsOf: magic)
        file.append(uint16LE: 0x001A) // data offset
        file.append(uint16LE: 0x010A) // version
        file.append(uint16LE: 0x1234) // checksum (unused)
        // Block: type 1, u24 size = 6.
        file.append(0x01)
        file.append(contentsOf: [UInt8(blockBody.count & 0xFF), 0x00, 0x00])
        file.append(contentsOf: blockBody)
        file.append(0x00) // terminator

        let sound = try Formats.Voc.decode(file)
        #expect(sound.sampleRate == 8000)
        #expect(sound.samples == samples)
    }

    @Test("bad magic is rejected")
    func badMagic() {
        let data = Data(count: 64)
        #expect(throws: Formats.Voc.DecodeError.self) {
            _ = try Formats.Voc.decode(data)
        }
    }

    @Test("continuation (type 2) block appends samples")
    func continuation() throws {
        let magic = Array("Creative Voice File\u{1A}".utf8)
        var file = Data()
        file.append(contentsOf: magic)
        file.append(uint16LE: 0x001A)
        file.append(uint16LE: 0x010A)
        file.append(uint16LE: 0)
        // Type 1 block: divisor 131 → 8000 Hz, 2 samples
        file.append(0x01)
        file.append(contentsOf: [4, 0, 0])
        file.append(contentsOf: [131, 0, 0x11, 0x22])
        // Type 2 block: 2 more samples
        file.append(0x02)
        file.append(contentsOf: [2, 0, 0])
        file.append(contentsOf: [0x33, 0x44])
        file.append(0x00)

        let sound = try Formats.Voc.decode(file)
        #expect(sound.sampleRate == 8000)
        #expect(sound.samples == [0x11, 0x22, 0x33, 0x44])
    }

    @Test("real VOC.PAK first VOC decodes")
    func realVocPak() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("VOC.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let entry = archive.entries.first(where: { $0.name.hasSuffix(".VOC") }) else {
            Issue.record("no .VOC entries in VOC.PAK")
            return
        }
        let sound = try Formats.Voc.decode(archive.body(for: entry))
        #expect(sound.sampleRate >= 4000)
        #expect(!sound.samples.isEmpty)
    }
}

extension Data {
    mutating fileprivate func append(uint16LE value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
}
