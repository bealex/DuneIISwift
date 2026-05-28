import Foundation
import Testing
@testable import DuneIIFormats

@Suite("Shp")
struct ShpTests {
    // One new-format 2x2 frame, raw RLE-zero payload (flag bit1 set): literal 5, zero-run 2, literal 6.
    static let synthetic = Data([
        0x01, 0x00,             // frame count = 1
        0x08, 0x00, 0x00, 0x00, // offset[0] = 8 (new format: 4 + 1*4 == 8)
        0x00, 0x00, 0x00, 0x00, // bytes 6-9 (new-format frame pointer is offset + 2 => header at 10)
        0x02, 0x00,             // flags = 0x0002 (raw RLE-zero, no lookup table)
        0x02,                   // height = 2
        0x02, 0x00,             // width = 2
        0x02,                   // height (duplicate)
        0x00, 0x00,             // packed size
        0x04, 0x00,             // decoded size (RLE stream length) = 4
        0x05, 0x00, 0x02, 0x06, // RLE: literal 5, zero-run of 2, literal 6
    ])

    @Test("decodes a frame with literals and a transparent zero-run")
    func frame() throws {
        let set = try Shp.FrameSet(ShpTests.synthetic)
        #expect(set.frames.count == 1)
        #expect(set.frames[0] == Shp.Frame(width: 2, height: 2, pixels: [ 5, 0, 0, 6 ], hasLookup: false))
    }

    @Test("real install SHP decodes; frames are width*height")
    func realData() throws {
        guard let bytes = TestInstall.pakEntry("DUNE.PAK", matchingSuffix: ".SHP") else { return }

        let set = try Shp.FrameSet(bytes)
        #expect(!set.frames.isEmpty)
        for frame in set.frames where frame.width > 0 {
            #expect(frame.pixels.count == frame.width * frame.height)
        }
    }
}
