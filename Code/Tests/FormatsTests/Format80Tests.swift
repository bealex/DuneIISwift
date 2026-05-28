import Foundation
import Testing
@testable import DuneIIFormats

@Suite("Format80")
struct Format80Tests {
    @Test("literal run copies bytes verbatim")
    func literalRun() throws {
        let decoded = try Format80.decode(Data([ 0x83, 0x41, 0x42, 0x43 ]), destinationLength: 3)
        #expect(decoded == Data([ 0x41, 0x42, 0x43 ]))
    }

    @Test("short relative copy — worked example ABCABC")
    func shortRelative() throws {
        let decoded = try Format80.decode(Data([ 0x83, 0x41, 0x42, 0x43, 0x00, 0x03 ]), destinationLength: 6)
        #expect(decoded == Data([ 0x41, 0x42, 0x43, 0x41, 0x42, 0x43 ]))
    }

    @Test("relative copy replicates on overlap (offset 1)")
    func relativeOverlapRun() throws {
        let decoded = try Format80.decode(Data([ 0x81, 0x41, 0x00, 0x01 ]), destinationLength: 4)
        #expect(decoded == Data([ 0x41, 0x41, 0x41, 0x41 ]))
    }

    @Test("short absolute copy from the start of the output")
    func shortAbsolute() throws {
        let source = Data([ 0x84, 0x41, 0x42, 0x43, 0x44, 0xC0, 0x00, 0x00 ])
        let decoded = try Format80.decode(source, destinationLength: 7)
        #expect(decoded == Data([ 0x41, 0x42, 0x43, 0x44, 0x41, 0x42, 0x43 ]))
    }

    @Test("long fill (0xFE) repeats a value")
    func longFill() throws {
        let decoded = try Format80.decode(Data([ 0xFE, 0x05, 0x00, 0x5A ]), destinationLength: 5)
        #expect(decoded == Data(repeating: 0x5A, count: 5))
    }

    @Test("long absolute copy (0xFF)")
    func longAbsolute() throws {
        let source = Data([ 0x82, 0x41, 0x42, 0xFF, 0x02, 0x00, 0x00, 0x00 ])
        let decoded = try Format80.decode(source, destinationLength: 4)
        #expect(decoded == Data([ 0x41, 0x42, 0x41, 0x42 ]))
    }

    @Test("0x80 ends decoding early and returns the prefix")
    func endMarker() throws {
        let decoded = try Format80.decode(Data([ 0x82, 0x41, 0x42, 0x80 ]), destinationLength: 10)
        #expect(decoded == Data([ 0x41, 0x42 ]))
    }

    @Test("size is clamped to the remaining destination")
    func sizeClamp() throws {
        // The literal command requests 63 bytes; the destination only has room for 2.
        let decoded = try Format80.decode(Data([ 0xBF, 0x41, 0x42 ]), destinationLength: 2)
        #expect(decoded == Data([ 0x41, 0x42 ]))
    }

    @Test("empty destination decodes to nothing")
    func emptyDestination() throws {
        let decoded = try Format80.decode(Data([ 0x83, 0x41 ]), destinationLength: 0)
        #expect(decoded.isEmpty)
    }

    @Test("truncated source throws")
    func truncatedSource() {
        #expect(throws: Format80.DecodeError.truncatedSource) {
            _ = try Format80.decode(Data([ 0x83, 0x41, 0x42 ]), destinationLength: 3)
        }
    }

    @Test("out-of-range back-reference throws")
    func invalidBackReference() {
        // Relative offset 5 with nothing written yet.
        #expect(throws: Format80.DecodeError.invalidBackReference) {
            _ = try Format80.decode(Data([ 0x00, 0x05 ]), destinationLength: 3)
        }
    }
}
