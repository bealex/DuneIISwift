import Foundation
import Testing
@testable import DuneIICore

@Suite("Codec.Format40")
struct Format40Tests {
    @Test("exit opcode terminates without modifying destination")
    func exit() throws {
        var dst = Data(repeating: 0x55, count: 4)
        try Codec.Format40.decode(source: Data([0x80, 0x00, 0x00]), destination: &dst)
        #expect(dst == Data(repeating: 0x55, count: 4))
    }

    @Test("XOR string against zeroed destination reproduces the string")
    func xorString() throws {
        // cmd with bit7 clear is a short XOR-string of length cmd.
        // Length 4, then four bytes.
        var src = Data([0x04, 0xDE, 0xAD, 0xBE, 0xEF])
        src.append(contentsOf: [0x80, 0x00, 0x00]) // exit
        var dst = Data(repeating: 0, count: 4)
        try Codec.Format40.decode(source: src, destination: &dst)
        #expect(dst == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("XOR repeated value (short form 0x00 LEN V)")
    func xorRepeatedShort() throws {
        var src = Data([0x00, 0x05, 0xFF])
        src.append(contentsOf: [0x80, 0x00, 0x00])
        var dst = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        try Codec.Format40.decode(source: src, destination: &dst)
        let expected: [UInt8] = [0x01 ^ 0xFF, 0x02 ^ 0xFF, 0x03 ^ 0xFF, 0x04 ^ 0xFF, 0x05 ^ 0xFF]
        #expect(dst == Data(expected))
    }

    @Test("skip leaves destination untouched")
    func skip() throws {
        // cmd in [0x81, 0xFF] with bit6 state irrelevant → skip (cmd & 0x7F)
        // 0x83 = skip 3 bytes.
        var src = Data([0x83])
        src.append(contentsOf: [0x02, 0xAA, 0xBB]) // then XOR 2 bytes
        src.append(contentsOf: [0x80, 0x00, 0x00])
        var dst = Data([0x10, 0x20, 0x30, 0x40, 0x50])
        try Codec.Format40.decode(source: src, destination: &dst)
        #expect(dst == Data([0x10, 0x20, 0x30, 0x40 ^ 0xAA, 0x50 ^ 0xBB]))
    }

    @Test("long skip via 0x80 LL LH with bit15 clear")
    func longSkip() throws {
        // 0x80 0x05 0x00 → skip 5 bytes, then exit.
        var src = Data([0x80, 0x05, 0x00])
        src.append(contentsOf: [0x01, 0xAA]) // XOR one byte at position 5
        src.append(contentsOf: [0x80, 0x00, 0x00])
        var dst = Data(repeating: 0xFF, count: 6)
        try Codec.Format40.decode(source: src, destination: &dst)
        var expected = Data(repeating: 0xFF, count: 6)
        expected[5] = 0xFF ^ 0xAA
        #expect(dst == expected)
    }

    @Test("long XOR-repeated (bit15+bit14 set)")
    func longXorRepeated() throws {
        // 0x80 <lo> <hi> with 0xC000 bits set and low 14 = count, then 1 value byte.
        // count = 4 → extended = 0xC004, lo=0x04 hi=0xC0
        var src = Data([0x80, 0x04, 0xC0, 0x0F])
        src.append(contentsOf: [0x80, 0x00, 0x00])
        var dst = Data([0xF0, 0xF0, 0xF0, 0xF0])
        try Codec.Format40.decode(source: src, destination: &dst)
        #expect(dst == Data([0xFF, 0xFF, 0xFF, 0xFF]))
    }

    @Test("destination overflow is raised")
    func overflow() {
        let src = Data([0x04, 0x01, 0x02, 0x03, 0x04, 0x80, 0x00, 0x00])
        var dst = Data(count: 2)
        #expect(throws: Codec.Format40.DecodeError.self) {
            try Codec.Format40.decode(source: src, destination: &dst)
        }
    }
}
