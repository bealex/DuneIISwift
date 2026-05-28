import Foundation
import Testing
@testable import DuneIIFormats

@Suite("Voc")
struct VocTests {
    static func synthetic() -> Data {
        var bytes = Array("Creative Voice File".utf8)   // 19 bytes
        bytes.append(0x1A)                              // terminator of the magic string (byte 19)
        bytes += [ 0x1A, 0x00 ]                         // offset to first block = 26 (bytes 20-21)
        bytes += [ 0x0A, 0x01 ]                         // version (22-23)
        bytes += [ 0x00, 0x00 ]                         // checksum (24-25)
        // Block @26: type 0x01, 24-bit length 6, freqDivisor 131 (=> 8000 Hz), codec 0, 4 PCM samples.
        bytes += [ 0x01, 0x06, 0x00, 0x00, 0x83, 0x00, 0x80, 0x81, 0x7F, 0x80 ]
        bytes += [ 0x00 ]                               // terminator block
        return Data(bytes)
    }

    @Test("decodes a type-0x01 sound block")
    func sound() throws {
        let sound = try Voc.decode(VocTests.synthetic())
        #expect(sound.sampleRate == 8000)
        #expect(sound.samples == [ 0x80, 0x81, 0x7F, 0x80 ])
    }

    @Test("real install VOC decodes")
    func realData() throws {
        guard let bytes = TestInstall.pakEntry("VOC.PAK", matchingSuffix: ".VOC") else { return }

        let sound = try Voc.decode(bytes)
        #expect(sound.sampleRate > 0)
        #expect(!sound.samples.isEmpty)
    }
}
