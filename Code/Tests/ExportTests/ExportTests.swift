import CoreGraphics
import Foundation
import ImageIO
import Testing
import DuneIIExport
import DuneIIFormats

@Suite("Export")
struct ExportTests {
    static func palette() -> Palette {
        var bytes = [UInt8](repeating: 0, count: 768)
        bytes[1 * 3] = 63       // index 1 = red
        bytes[2 * 3 + 1] = 63   // index 2 = green
        bytes[3 * 3 + 2] = 63   // index 3 = blue
        return try! Palette(Data(bytes))
    }

    @Test("PNG encodes a valid, correctly-sized image")
    func png() throws {
        let indices: [UInt8] = [ 0, 1, 2, 3 ]   // 2x2: transparent, red, green, blue
        let data = try PngWriter.encode(
            indices: indices, width: 2, height: 2, palette: ExportTests.palette(), transparentIndex: 0
        )

        #expect(Array(data.prefix(4)) == [ 0x89, 0x50, 0x4E, 0x47 ])   // PNG signature

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 2)
        #expect(image.height == 2)
    }

    @Test("PNG rejects mismatched dimensions")
    func pngInvalid() {
        #expect(throws: PngWriter.WriteError.invalidDimensions) {
            _ = try PngWriter.encode(indices: [ 0, 1 ], width: 4, height: 4, palette: ExportTests.palette())
        }
    }

    @Test("WAV writes a parseable RIFF/WAVE file with the samples")
    func wav() {
        let samples: [UInt8] = [ 0x80, 0x81, 0x7F, 0x80 ]
        let bytes = [UInt8](WavWriter.encode(samples: samples, sampleRate: 8000))

        #expect(Array(bytes.prefix(4)) == Array("RIFF".utf8))
        #expect(Array(bytes[8 ..< 12]) == Array("WAVE".utf8))
        let rate = Int(bytes[24]) | (Int(bytes[25]) << 8) | (Int(bytes[26]) << 16) | (Int(bytes[27]) << 24)
        #expect(rate == 8000)
        #expect(Array(bytes[36 ..< 40]) == Array("data".utf8))
        let dataLength = Int(bytes[40]) | (Int(bytes[41]) << 8) | (Int(bytes[42]) << 16) | (Int(bytes[43]) << 24)
        #expect(dataLength == 4)
        #expect(Array(bytes[44 ..< 48]) == samples)
    }
}
