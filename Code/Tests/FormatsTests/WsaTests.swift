import Foundation
import Testing

@testable import DuneIIFormats

@Suite("Wsa")
struct WsaTests {
    // Two 2x2 frames. Frame 0 builds [1,2,3,4]; frame 1 XOR-flips pixel 1 (2 -> 2^0x0F = 13).
    // Each frame chunk is a Format80 literal run wrapping a Format40 delta stream.
    static let synthetic = Data([
        // header (10): frames=2, width=2, height=2, requiredBufferSize=0, hasPalette=0
        0x02, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
        // offset table (frames+2 = 4 entries): 26, 36, 44, 0
        0x1A, 0x00, 0x00, 0x00,
        0x24, 0x00, 0x00, 0x00,
        0x2C, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        // frame 0 @26: F80 literal-run(8) [ Format40: xor-string 4 = 01 02 03 04, terminator ] F80-end
        0x88, 0x04, 0x01, 0x02, 0x03, 0x04, 0x80, 0x00, 0x00, 0x80,
        // frame 1 @36: F80 literal-run(6) [ Format40: skip 1, xor-string 1 = 0F, terminator ] F80-end
        0x86, 0x81, 0x01, 0x0F, 0x80, 0x00, 0x00, 0x80,
    ])

    @Test("decodes frames via Format80 then Format40 XOR carry-over")
    func frames() throws {
        let animation = try Wsa.Animation(WsaTests.synthetic)
        #expect(animation.width == 2)
        #expect(animation.height == 2)
        #expect(animation.frames.count == 2)
        #expect(animation.frames[0] == [ 1, 2, 3, 4 ])
        #expect(animation.frames[1] == [ 1, 13, 3, 4 ])
    }

    @Test("real install WSA decodes; frames are width*height")
    func realData() throws {
        guard let bytes = TestInstall.pakEntry("DUNE.PAK", matchingSuffix: ".WSA") else { return }

        let animation = try Wsa.Animation(bytes)
        #expect(!animation.frames.isEmpty)
        for frame in animation.frames {
            #expect(frame.count == animation.width * animation.height)
        }
    }
}
