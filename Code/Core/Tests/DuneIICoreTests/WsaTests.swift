import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Wsa")
struct WsaTests {
    @Test("real STATIC.WSA decodes into complete frames")
    func realStatic() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("DUNE.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let data = archive.body(named: "STATIC.WSA") else { return }
        let anim = try Formats.Wsa.decode(data)
        #expect(anim.frames.count > 0)
        for frame in anim.frames {
            #expect(frame.count == anim.width * anim.height)
        }
    }

    @Test("real LOSTVEHC.WSA decodes without error")
    func realLostVehicle() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("DUNE.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let data = archive.body(named: "LOSTVEHC.WSA") else { return }
        let anim = try Formats.Wsa.decode(data)
        #expect(anim.width > 0)
        #expect(anim.height > 0)
        #expect(anim.frames.count >= 1)
    }

    @Test("truncated WSA is rejected")
    func truncated() {
        let data = Data(count: 8) // too small even for the legacy header + minimal offsets
        #expect(throws: Formats.Wsa.DecodeError.self) {
            _ = try Formats.Wsa.decode(data)
        }
    }

    @Test("synthetic single-frame modern WSA renders a constant fill")
    func syntheticSingleFrame() throws {
        let w = 4, h = 2
        // Format40 XOR stream: `0x08` cmd = XOR-string of length 8, bytes all 0xAB, then exit.
        let f40Exit: [UInt8] = [0x80, 0x00, 0x00]
        let f40Body: [UInt8] = [UInt8(w * h)] + [UInt8](repeating: 0xAB, count: w * h) + f40Exit
        // Format80-encode the f40 stream with a short literal copy, then exit.
        let literalSize = f40Body.count
        precondition(literalSize < 0x3F, "test stream must fit in one short literal")
        var f80 = Data()
        f80.append(0x80 | UInt8(literalSize))
        f80.append(contentsOf: f40Body)
        f80.append(0x80)

        // Header: 10 bytes. frames=1, w, h, requiredBuf=64, hasPalette=0.
        var file = Data()
        file.append(uint16LE: 1)
        file.append(uint16LE: UInt16(w))
        file.append(uint16LE: UInt16(h))
        file.append(uint16LE: 64)
        file.append(uint16LE: 0)
        // 3 u32 offsets (frames + 2). offset[0] = 10 + 8 + 4*1 = 22.
        let off0: UInt32 = 22
        let off1: UInt32 = off0 + UInt32(f80.count)
        let off2: UInt32 = off1 // sentinel — no extra animation
        file.append(uint32LE: off0)
        file.append(uint32LE: off1)
        file.append(uint32LE: off2)
        file.append(f80)

        let anim = try Formats.Wsa.decode(file)
        #expect(anim.frames.count == 1)
        #expect(anim.frames[0] == [UInt8](repeating: 0xAB, count: w * h))
    }

    @Test("continuation WSA: offset[0]=0 yields an initial zero frame, not an error")
    func continuationFile() throws {
        let w = 2, h = 2
        // One "real" XOR stream for frame 1, flipping nothing.
        let exit: [UInt8] = [0x80, 0x00, 0x00]
        var f80 = Data()
        f80.append(0x80 | UInt8(exit.count))
        f80.append(contentsOf: exit)
        f80.append(0x80)

        var file = Data()
        file.append(uint16LE: 2) // frames
        file.append(uint16LE: UInt16(w))
        file.append(uint16LE: UInt16(h))
        file.append(uint16LE: 64)
        file.append(uint16LE: 0)

        let headerEnd: UInt32 = 10 + 8 + 4 * 2 // = 26
        // offset[0] = 0 (continuation), offset[1] = start of real frame, offset[2] = end, offset[3] = sentinel.
        file.append(uint32LE: 0)
        file.append(uint32LE: headerEnd)
        file.append(uint32LE: headerEnd + UInt32(f80.count))
        file.append(uint32LE: headerEnd + UInt32(f80.count))
        file.append(f80)

        let anim = try Formats.Wsa.decode(file)
        #expect(anim.frames.count == 2)
        #expect(anim.frames[0] == [UInt8](repeating: 0, count: w * h))
        #expect(anim.frames[1] == [UInt8](repeating: 0, count: w * h))
    }
}

private extension Data {
    mutating func append(uint16LE value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func append(uint32LE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
