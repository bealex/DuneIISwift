import Foundation
import Testing
@testable import DuneIIFormats

@Suite("Format40")
struct Format40Tests {
    @Test("XOR with a string of bytes")
    func xorString() throws {
        var dest: [UInt8] = [ 0, 0, 0, 0 ]
        try Format40.decodeXOR(into: &dest, source: Data([ 0x02, 0x05, 0x0A, 0x80, 0x00, 0x00 ]))
        #expect(dest == [ 5, 10, 0, 0 ])
    }

    @Test("XOR-fill repeats one value (cmd 0)")
    func xorFill() throws {
        var dest: [UInt8] = [ 0, 0, 0, 0, 0 ]
        try Format40.decodeXOR(into: &dest, source: Data([ 0x00, 0x03, 0xFF, 0x80, 0x00, 0x00 ]))
        #expect(dest == [ 0xFF, 0xFF, 0xFF, 0, 0 ])
    }

    @Test("skip leaves bytes unchanged from the previous frame")
    func skip() throws {
        var dest: [UInt8] = [ 1, 2, 3, 4 ]
        try Format40.decodeXOR(into: &dest, source: Data([ 0x82, 0x02, 0x0F, 0x05, 0x80, 0x00, 0x00 ]))
        #expect(dest == [ 1, 2, 12, 1 ])
    }

    @Test("extended skip (0x80, bit15 clear)")
    func extendedSkip() throws {
        var dest: [UInt8] = [ 1, 2, 3, 4 ]
        try Format40.decodeXOR(into: &dest, source: Data([ 0x80, 0x03, 0x00, 0x01, 0x0F, 0x80, 0x00, 0x00 ]))
        #expect(dest == [ 1, 2, 3, 11 ])
    }

    @Test("extended XOR-string (0x80, bit15 set, bit14 clear)")
    func extendedXorString() throws {
        var dest: [UInt8] = [ 1, 2, 3, 4 ]
        try Format40.decodeXOR(into: &dest, source: Data([ 0x80, 0x02, 0x80, 0x0F, 0x0F, 0x80, 0x00, 0x00 ]))
        #expect(dest == [ 14, 13, 3, 4 ])
    }

    @Test("extended XOR-fill (0x80, bit15 and bit14 set)")
    func extendedXorFill() throws {
        var dest: [UInt8] = [ 0, 0, 0, 0 ]
        try Format40.decodeXOR(into: &dest, source: Data([ 0x80, 0x03, 0xC0, 0xFF, 0x80, 0x00, 0x00 ]))
        #expect(dest == [ 0xFF, 0xFF, 0xFF, 0 ])
    }

    @Test("terminator leaves the buffer untouched")
    func terminator() throws {
        var dest: [UInt8] = [ 1, 2 ]
        try Format40.decodeXOR(into: &dest, source: Data([ 0x80, 0x00, 0x00 ]))
        #expect(dest == [ 1, 2 ])
    }

    @Test("writing past the destination throws")
    func destinationOverflow() {
        var dest: [UInt8] = [ 0 ]
        #expect(throws: Format40.DecodeError.destinationOverflow) {
            try Format40.decodeXOR(into: &dest, source: Data([ 0x02, 0x05, 0x0A, 0x80, 0x00, 0x00 ]))
        }
    }

    @Test("truncated source throws")
    func truncatedSource() {
        var dest: [UInt8] = [ 0, 0 ]
        #expect(throws: Format40.DecodeError.truncatedSource) {
            try Format40.decodeXOR(into: &dest, source: Data([ 0x02, 0x05 ]))
        }
    }
}
