import Foundation
import Testing
@testable import DuneIIFormats

@Suite("Iff")
struct IffTests {
    // FORM "EMC2" with TEXT (3 bytes, odd → padded) and DATA (2 bytes).
    static let synthetic = Data([
        0x46, 0x4F, 0x52, 0x4D,   // "FORM"
        0x00, 0x00, 0x00, 0x1A,   // total length 26 (big-endian, ignored)
        0x45, 0x4D, 0x43, 0x32,   // form type "EMC2"
        0x54, 0x45, 0x58, 0x54,   // "TEXT"
        0x00, 0x00, 0x00, 0x03,   // length 3 (big-endian)
        0x01, 0x02, 0x03,         // payload
        0x00,                     // pad byte (odd length)
        0x44, 0x41, 0x54, 0x41,   // "DATA"
        0x00, 0x00, 0x00, 0x02,   // length 2
        0x04, 0x05,               // payload
    ])

    @Test("reads form type and chunks, honoring word padding")
    func chunks() throws {
        let reader = try Iff.Reader(IffTests.synthetic)
        #expect(reader.formType == "EMC2")
        #expect(reader.chunk("TEXT") == Data([ 0x01, 0x02, 0x03 ]))
        #expect(reader.chunk("DATA") == Data([ 0x04, 0x05 ]))
        #expect(reader.chunk("NOPE") == nil)
    }

    @Test("non-FORM input throws")
    func notForm() {
        #expect(throws: Iff.DecodeError.notForm) {
            _ = try Iff.Reader(Data(count: 12))
        }
    }
}
