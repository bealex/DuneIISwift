import Foundation
import ImageIO
import Testing
@testable import DuneIICore
@testable import AssetExport

@Suite("AssetExport")
struct AssetExportTests {
    // MARK: WAVWriter

    @Test("WAV header has correct RIFF structure and sample rate")
    func wavHeaderLayout() throws {
        let samples: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let tmp = try temporaryFile(ext: "wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try WAVWriter.write(samples: samples, sampleRate: 16000, to: tmp)
        let data = try Data(contentsOf: tmp)

        #expect(data.count == 44 + samples.count)
        // RIFF chunk
        #expect(String(bytes: data[0..<4], encoding: .ascii) == "RIFF")
        #expect(readU32LE(data, at: 4) == UInt32(36 + samples.count))
        #expect(String(bytes: data[8..<12], encoding: .ascii) == "WAVE")
        // fmt chunk
        #expect(String(bytes: data[12..<16], encoding: .ascii) == "fmt ")
        #expect(readU32LE(data, at: 16) == 16)         // fmt chunk size
        #expect(readU16LE(data, at: 20) == 1)          // PCM
        #expect(readU16LE(data, at: 22) == 1)          // mono
        #expect(readU32LE(data, at: 24) == 16000)      // sample rate
        #expect(readU32LE(data, at: 28) == 16000)      // byte rate
        #expect(readU16LE(data, at: 32) == 1)          // block align
        #expect(readU16LE(data, at: 34) == 8)          // bits per sample
        // data chunk
        #expect(String(bytes: data[36..<40], encoding: .ascii) == "data")
        #expect(readU32LE(data, at: 40) == UInt32(samples.count))
        #expect(Array(data[44..<(44 + samples.count)]) == samples)
    }

    // MARK: PaletteRenderer

    @Test("PalettedImage.render scales 6-bit VGA values with bit replication")
    func paletteRenderScaling() throws {
        var palBytes = Data(count: 768)
        palBytes[0] = 63; palBytes[1] = 63; palBytes[2] = 63  // index 0 white
        palBytes[3] = 0;  palBytes[4] = 63; palBytes[5] = 0   // index 1 pure green
        let palette = try Formats.Palette(data: palBytes)

        let rgba = PalettedImage.render(pixels: [0, 1], width: 2, height: 1, palette: palette, mode: .opaque)
        #expect(rgba == [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF])
    }

    @Test("index 0 transparent mode yields alpha=0 for palette slot 0")
    func paletteIndex0Transparent() throws {
        var palBytes = Data(count: 768)
        palBytes[0] = 63; palBytes[1] = 0; palBytes[2] = 0 // red at 0 (real value)
        palBytes[3] = 0;  palBytes[4] = 0; palBytes[5] = 63 // blue at 1
        let palette = try Formats.Palette(data: palBytes)

        let rgba = PalettedImage.render(pixels: [0, 1], width: 2, height: 1, palette: palette, mode: .index0Transparent)
        #expect(rgba[3] == 0)            // alpha of pixel 0
        #expect(rgba[7] == 0xFF)         // alpha of pixel 1
        #expect(rgba[4..<7] == [0x00, 0x00, 0xFF])
    }

    // MARK: PNGWriter

    @Test("PNGWriter produces a file ImageIO can read back")
    func pngRoundTrip() throws {
        let w = 4, h = 3
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4 + 0] = UInt8(i * 10)
            rgba[i * 4 + 1] = 0x20
            rgba[i * 4 + 2] = 0x30
            rgba[i * 4 + 3] = 0xFF
        }
        let tmp = try temporaryFile(ext: "png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try PNGWriter.write(rgba: rgba, width: w, height: h, to: tmp)
        guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            Issue.record("failed to re-read PNG")
            return
        }
        #expect(img.width == w)
        #expect(img.height == h)
    }

    // MARK: Extractors (file layout)

    @Test("extractVoc writes a WAV at the expected Audio/Voc path")
    func extractVocLayout() throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let magic = Array("Creative Voice File\u{1A}".utf8)
        var voc = Data()
        voc.append(contentsOf: magic)
        voc.append(contentsOf: [0x1A, 0x00, 0x0A, 0x01, 0x34, 0x12])
        voc.append(0x01); voc.append(contentsOf: [6, 0, 0])
        voc.append(contentsOf: [131, 0, 10, 20, 30, 40])
        voc.append(0x00)

        let ctx = ExtractContext(outputRoot: tmp, fallbackPalette: nil, logger: SilentLogger())
        try Extractors.extractVoc(name: "TEST", data: voc, ctx: ctx)

        let wav = tmp.appendingPathComponent("Audio/Voc/TEST.wav")
        #expect(FileManager.default.fileExists(atPath: wav.path))
        let bytes = try Data(contentsOf: wav)
        #expect(readU32LE(bytes, at: 24) == 8000) // sample rate
    }

    @Test("extractPalette writes both JSON and PNG swatch")
    func extractPaletteLayout() throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        var palBytes = Data(count: 768)
        for i in 0..<256 {
            palBytes[i * 3] = UInt8(i & 0x3F)
        }
        let ctx = ExtractContext(outputRoot: tmp, fallbackPalette: nil, logger: SilentLogger())
        try Extractors.extractPalette(name: "IBM", data: palBytes, ctx: ctx)

        let json = tmp.appendingPathComponent("Palettes/IBM.json")
        let png = tmp.appendingPathComponent("Palettes/IBM.png")
        #expect(FileManager.default.fileExists(atPath: json.path))
        #expect(FileManager.default.fileExists(atPath: png.path))
        let jsonText = try String(contentsOf: json, encoding: .utf8)
        #expect(jsonText.contains("\"r6\""))
    }

    @Test("extractShp writes per-frame PNGs + index.json")
    func extractShpLayout() throws {
        let tmp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Build the same 4×2 raw SHP the ShpTests suite uses.
        let stream: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let frame = buildModernShp(flags: 0x0002, width: 4, height: 2, pixelStream: stream)

        // A minimal 768-byte palette where every slot is solid red so
        // index 0 is clearly distinguishable (it stays transparent).
        var palBytes = Data(count: 768)
        for i in 0..<256 { palBytes[i * 3] = 63 }
        let palette = try Formats.Palette(data: palBytes)
        let ctx = ExtractContext(outputRoot: tmp, fallbackPalette: palette, logger: SilentLogger())
        try Extractors.extractShp(name: "TEST", data: frame, ctx: ctx)

        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Sprites/TEST/000.png").path))
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Sprites/TEST/index.json").path))
    }
}

// MARK: - Helpers

private func temporaryFile(ext: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
    return dir.appendingPathComponent("assetgen-\(UUID().uuidString).\(ext)")
}

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("assetgen-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func readU16LE(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readU32LE(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

/// Duplicated here so AssetExportTests doesn't import from ShpTests.
private func buildModernShp(flags: UInt16, width: Int, height: Int, pixelStream: [UInt8]) -> Data {
    let headerBlockSize = 10 + pixelStream.count
    let offset0 = 8
    let fileSize = offset0 + 2 + headerBlockSize
    var file = Data()
    file.append(UInt8(1)); file.append(UInt8(0))                   // count = 1
    file.append(UInt8(offset0)); file.append(contentsOf: [0, 0, 0]) // offset[0]
    let term = UInt32(fileSize - 2)
    file.append(UInt8(term & 0xFF))
    file.append(UInt8((term >> 8) & 0xFF))
    file.append(UInt8((term >> 16) & 0xFF))
    file.append(UInt8((term >> 24) & 0xFF))
    file.append(UInt8(flags & 0xFF)); file.append(UInt8(flags >> 8))
    file.append(UInt8(height))
    file.append(UInt8(width & 0xFF)); file.append(UInt8(width >> 8))
    file.append(UInt8(height))
    file.append(UInt8(0)); file.append(UInt8(0))                   // packed
    file.append(UInt8(pixelStream.count & 0xFF)); file.append(UInt8(pixelStream.count >> 8))
    file.append(contentsOf: pixelStream)
    return file
}
