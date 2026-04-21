import Foundation
import Testing
@testable import DuneIICore

@Suite("Codec.Format80")
struct Format80Tests {
    @Test("exit command yields empty output")
    func exit() throws {
        let out = try Codec.Format80.decode(Data([0x80]), destinationCapacity: 0)
        #expect(out == Data())
    }

    @Test("short literal copy reproduces bytes")
    func shortLiteralCopy() throws {
        // cmd = 0x80 | size with bit6 clear → cmd in [0x81, 0xBF]; size = cmd & 0x3F
        // Copy 5 literal bytes then exit.
        let stream = Data([0x85, 1, 2, 3, 4, 5, 0x80])
        let out = try Codec.Format80.decode(stream, destinationCapacity: 5)
        #expect(out == Data([1, 2, 3, 4, 5]))
    }

    @Test("short relative copy: repeat previously written byte")
    func shortRelativeCopy() throws {
        // First emit one literal byte (0xAA), then do a short relative copy
        // of length 5 with offset 1 (should replicate the last byte).
        // Short relative: cmd bit7 = 0; len = (cmd >> 4) + 3; offset = ((cmd & 0x0F) << 8) | next.
        // len=5 → (cmd >> 4) = 2 → cmd high nibble = 0x2.
        // offset=1 → (cmd & 0x0F)=0, next byte = 0x01. So cmd = 0x20, next = 0x01.
        var stream = Data([0x81, 0xAA])    // literal: 0xAA
        stream.append(contentsOf: [0x20, 0x01])
        stream.append(0x80)
        let out = try Codec.Format80.decode(stream, destinationCapacity: 6)
        #expect(out == Data([0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA]))
    }

    @Test("long fill (0xFE) writes a run of a constant value")
    func longFill() throws {
        // 0xFE LL LH V → fill (LH:LL) copies of V
        // length = 10
        let stream = Data([0xFE, 0x0A, 0x00, 0x5A, 0x80])
        let out = try Codec.Format80.decode(stream, destinationCapacity: 10)
        #expect(out == Data(repeating: 0x5A, count: 10))
    }

    @Test("long absolute copy (0xFF) copies from an absolute position")
    func longAbsoluteCopy() throws {
        // Write 4 literal bytes, then long absolute copy of length 3 from offset 1.
        var stream = Data([0x84, 0x10, 0x20, 0x30, 0x40])       // [10 20 30 40]
        stream.append(contentsOf: [0xFF, 0x03, 0x00, 0x01, 0x00]) // copy 3 bytes from index 1
        stream.append(0x80)
        let out = try Codec.Format80.decode(stream, destinationCapacity: 7)
        #expect(out == Data([0x10, 0x20, 0x30, 0x40, 0x20, 0x30, 0x40]))
    }

    @Test("short absolute copy (cmd & 0x40) copies from absolute position")
    func shortAbsoluteCopy() throws {
        // Literal 4 bytes, then short absolute: len = (cmd & 0x3F) + 3, offset = next16.
        // len = 3 → cmd & 0x3F = 0 → cmd = 0xC0.
        var stream = Data([0x84, 0xAA, 0xBB, 0xCC, 0xDD])
        stream.append(contentsOf: [0xC0, 0x00, 0x00]) // copy 3 bytes from offset 0
        stream.append(0x80)
        let out = try Codec.Format80.decode(stream, destinationCapacity: 7)
        #expect(out == Data([0xAA, 0xBB, 0xCC, 0xDD, 0xAA, 0xBB, 0xCC]))
    }

    @Test("output is clamped to destination capacity")
    func clampedToCapacity() throws {
        // Short literal copy asking for 5 bytes but capacity is 3 → we should not overflow.
        let stream = Data([0x85, 1, 2, 3, 4, 5])
        // The decoder clamps size to remaining capacity and keeps going until exit.
        // Since stream has no exit after the literals, the loop should end when dp==capacity.
        let out = try Codec.Format80.decode(stream, destinationCapacity: 3)
        #expect(out == Data([1, 2, 3]))
    }

    @Test("truncated source raises truncated")
    func truncated() {
        // 0xFE expects two more bytes then a value; only one following byte.
        let stream = Data([0xFE, 0x01])
        #expect(throws: Codec.Format80.DecodeError.self) {
            _ = try Codec.Format80.decode(stream, destinationCapacity: 1)
        }
    }
}
