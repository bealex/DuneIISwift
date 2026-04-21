import Foundation
import DuneIICore

public protocol ExtractLogger: Sendable {
    func info(_ s: String)
    func detail(_ s: @autoclosure () -> String)
    func warn(_ s: String)
}

public struct SilentLogger: ExtractLogger {
    public init() {}
    public func info(_ s: String) {}
    public func detail(_ s: @autoclosure () -> String) {}
    public func warn(_ s: String) {}
}

public struct ExtractContext {
    public let outputRoot: URL
    public let fallbackPalette: Formats.Palette?
    public let logger: ExtractLogger

    public init(outputRoot: URL, fallbackPalette: Formats.Palette?, logger: ExtractLogger) {
        self.outputRoot = outputRoot
        self.fallbackPalette = fallbackPalette
        self.logger = logger
    }

    public func dir(_ components: String...) -> URL {
        var url = outputRoot
        for c in components { url.appendPathComponent(c) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public enum Extractors {
    // MARK: Palette

    public static func extractPalette(name: String, data: Data, ctx: ExtractContext) throws {
        let palette = try Formats.Palette(data: data)
        let dir = ctx.dir("Palettes")

        // JSON mirror of the 6-bit values and scaled RGB8.
        struct Entry: Encodable {
            let r6: UInt8
            let g6: UInt8
            let b6: UInt8
            let rgba8: String
        }
        let json = palette.colors.map { c -> Entry in
            Entry(
                r6: c.r6, g6: c.g6, b6: c.b6,
                rgba8: String(format: "#%08X", c.rgba8)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(json)
        try encoded.write(to: dir.appendingPathComponent("\(name).json"))

        // Small PNG swatch — 16×16 grid of 16px squares for eyeballing.
        let swatchPx = 16
        let cols = 16
        let rows = 16
        let w = cols * swatchPx
        let h = rows * swatchPx
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let col = x / swatchPx
                let row = y / swatchPx
                let idx = row * cols + col
                let c = palette.colors[idx]
                let r = (c.r6 << 2) | (c.r6 >> 4)
                let g = (c.g6 << 2) | (c.g6 >> 4)
                let b = (c.b6 << 2) | (c.b6 >> 4)
                let base = (y * w + x) * 4
                rgba[base] = r; rgba[base + 1] = g; rgba[base + 2] = b; rgba[base + 3] = 0xFF
            }
        }
        try PNGWriter.write(rgba: rgba, width: w, height: h, to: dir.appendingPathComponent("\(name).png"))
    }

    // MARK: CPS

    public static func extractCps(name: String, data: Data, ctx: ExtractContext) throws {
        let image = try Formats.Cps.decode(data)
        let palette = image.palette ?? ctx.fallbackPalette
        guard let palette else { throw AssetgenError.missingFallbackPalette }
        let rgba = PalettedImage.render(
            pixels: image.pixels,
            width: Formats.Cps.Image.width,
            height: Formats.Cps.Image.height,
            palette: palette,
            mode: .opaque
        )
        let url = ctx.dir("Screens").appendingPathComponent("\(name).png")
        try PNGWriter.write(rgba: rgba, width: Formats.Cps.Image.width, height: Formats.Cps.Image.height, to: url)
    }

    // MARK: SHP

    public static func extractShp(name: String, data: Data, ctx: ExtractContext) throws {
        let set = try Formats.Shp.decode(data)
        guard let palette = ctx.fallbackPalette else { throw AssetgenError.missingFallbackPalette }
        let dir = ctx.dir("Sprites", name)
        for (i, frame) in set.frames.enumerated() {
            let rgba = PalettedImage.render(
                pixels: frame.pixels,
                width: frame.width,
                height: frame.height,
                palette: palette,
                mode: .index0Transparent
            )
            let fileName = String(format: "%03d.png", i)
            try PNGWriter.write(rgba: rgba, width: frame.width, height: frame.height,
                                to: dir.appendingPathComponent(fileName))
        }
        // Index JSON so callers don't need to guess dimensions.
        struct FrameMeta: Encodable {
            let index: Int
            let width: Int
            let height: Int
            let hasHousePalette: Bool
        }
        let metas = set.frames.enumerated().map { (i, f) in
            FrameMeta(index: i, width: f.width, height: f.height, hasHousePalette: f.hasHousePalette)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metas).write(to: dir.appendingPathComponent("index.json"))
    }

    // MARK: WSA

    public static func extractWsa(name: String, data: Data, ctx: ExtractContext) throws {
        let anim = try Formats.Wsa.decode(data)
        let palette = anim.palette ?? ctx.fallbackPalette
        guard let palette else { throw AssetgenError.missingFallbackPalette }
        let dir = ctx.dir("Animations", name)
        for (i, frame) in anim.frames.enumerated() {
            let rgba = PalettedImage.render(
                pixels: frame,
                width: anim.width,
                height: anim.height,
                palette: palette,
                mode: .opaque
            )
            let fileName = String(format: "%03d.png", i)
            try PNGWriter.write(rgba: rgba, width: anim.width, height: anim.height,
                                to: dir.appendingPathComponent(fileName))
        }
    }

    // MARK: ICN (tile atlas)

    public static func extractIcn(name: String, data: Data, ctx: ExtractContext) throws {
        let tiles = try Formats.Icn.decode(data)
        guard let palette = ctx.fallbackPalette else { throw AssetgenError.missingFallbackPalette }
        let tileW = tiles.tileWidth
        let tileH = tiles.tileHeight
        let cols = 32
        let rows = (tiles.tileCount + cols - 1) / cols
        let atlasW = cols * tileW
        let atlasH = rows * tileH
        var rgba = [UInt8](repeating: 0, count: atlasW * atlasH * 4)
        for i in 0..<tiles.tileCount {
            let col = i % cols
            let row = i / cols
            let pixels = tiles.pixels(forTile: i)
            for y in 0..<tileH {
                for x in 0..<tileW {
                    let idx = Int(pixels[y * tileW + x])
                    let c = palette.colors[idx]
                    let r = (c.r6 << 2) | (c.r6 >> 4)
                    let g = (c.g6 << 2) | (c.g6 >> 4)
                    let b = (c.b6 << 2) | (c.b6 >> 4)
                    let dx = col * tileW + x
                    let dy = row * tileH + y
                    let base = (dy * atlasW + dx) * 4
                    // Tile index 0 often means "empty" — but not always. For the
                    // atlas, treat every tile as opaque so the layout stays
                    // inspectable. Index-0 transparency is applied at draw time.
                    rgba[base] = r; rgba[base + 1] = g; rgba[base + 2] = b; rgba[base + 3] = 0xFF
                }
            }
        }
        let dir = ctx.dir("Tiles")
        try PNGWriter.write(rgba: rgba, width: atlasW, height: atlasH,
                            to: dir.appendingPathComponent("\(name).png"))

        struct TileInfo: Encodable {
            let tileWidth: Int
            let tileHeight: Int
            let tileCount: Int
            let atlasColumns: Int
            let rtbl: [UInt8]
        }
        let info = TileInfo(
            tileWidth: tileW, tileHeight: tileH, tileCount: tiles.tileCount,
            atlasColumns: cols, rtbl: tiles.rtbl
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(info).write(to: dir.appendingPathComponent("\(name).json"))
    }

    // MARK: FNT (font sheet)

    public static func extractFnt(name: String, data: Data, ctx: ExtractContext) throws {
        let font = try Formats.Fnt.decode(data)
        let cell = max(16, font.maxWidth)
        let cellH = max(16, font.height)
        let cols = 16
        let rows = (font.glyphs.count + cols - 1) / cols
        let sheetW = cols * cell
        let sheetH = rows * cellH
        var rgba = [UInt8](repeating: 0, count: sheetW * sheetH * 4)

        // Light-gray backdrop so glyphs stay readable in any viewer, with a
        // 1px cell separator every `cell` pixels. Glyphs paint as solid black.
        for y in 0..<sheetH {
            for x in 0..<sheetW {
                let base = (y * sheetW + x) * 4
                let onGrid = (x % cell == 0) || (y % cellH == 0)
                let v: UInt8 = onGrid ? 0xB0 : 0xE0
                rgba[base] = v; rgba[base + 1] = v; rgba[base + 2] = v; rgba[base + 3] = 0xFF
            }
        }
        for (i, g) in font.glyphs.enumerated() {
            let col = i % cols
            let row = i / cols
            let originX = col * cell
            let originY = row * cellH + g.unusedLines
            for y in 0..<g.usedLines {
                for x in 0..<g.width {
                    let v = g.pixels[y * g.width + x]
                    if v == 0 { continue }
                    let dx = originX + x
                    let dy = originY + y
                    if dx >= sheetW || dy >= sheetH { continue }
                    let base = (dy * sheetW + dx) * 4
                    rgba[base] = 0x00; rgba[base + 1] = 0x00; rgba[base + 2] = 0x00; rgba[base + 3] = 0xFF
                }
            }
        }
        let dir = ctx.dir("Fonts")
        try PNGWriter.write(rgba: rgba, width: sheetW, height: sheetH,
                            to: dir.appendingPathComponent("\(name).png"))

        struct GlyphMeta: Encodable {
            let index: Int
            let width: Int
            let unusedLines: Int
            let usedLines: Int
        }
        let metas = font.glyphs.enumerated().map { (i, g) in
            GlyphMeta(index: i, width: g.width, unusedLines: g.unusedLines, usedLines: g.usedLines)
        }
        struct FontInfo: Encodable {
            let height: Int
            let maxWidth: Int
            let sheetColumns: Int
            let cellWidth: Int
            let cellHeight: Int
            let glyphs: [GlyphMeta]
        }
        let info = FontInfo(
            height: font.height, maxWidth: font.maxWidth,
            sheetColumns: cols, cellWidth: cell, cellHeight: cellH,
            glyphs: metas
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(info).write(to: dir.appendingPathComponent("\(name).json"))
    }

    // MARK: VOC

    public static func extractVoc(name: String, data: Data, ctx: ExtractContext) throws {
        let sound = try Formats.Voc.decode(data)
        let url = ctx.dir("Audio", "Voc").appendingPathComponent("\(name).wav")
        try WAVWriter.write(samples: sound.samples, sampleRate: sound.sampleRate, to: url)
    }

    // MARK: XMI (music → SMF)

    public static func extractXmi(name: String, data: Data, ctx: ExtractContext) throws {
        let song = try Formats.Xmi.Song.decode(data)
        let dir = ctx.dir("Audio", "Music")
        // Dune II packs many empty slots per XMI — only emit tracks that
        // actually contain note events, otherwise we bury the useful files
        // under ~1500 near-identical placeholders.
        let realTracks = song.tracks.enumerated().filter { _, track in
            track.events.contains(where: { ($0.bytes.first ?? 0) & 0xF0 == 0x90 })
        }
        for (i, track) in realTracks {
            let smf = track.toStandardMidiFile()
            let fileName = realTracks.count == 1
                ? "\(name).mid"
                : String(format: "%@.%02d.mid", name, i)
            try smf.write(to: dir.appendingPathComponent(fileName))
        }
    }

    // MARK: EMC (compiled scripts)

    public static func extractEmc(name: String, data: Data, ctx: ExtractContext) throws {
        let program = try Formats.Emc.Program.decode(data)
        let dir = ctx.dir("Scripts", name)

        // Raw bytes — stays playable by the VM in P4 with no conversion.
        try data.write(to: dir.appendingPathComponent("\(name).emc"))

        // A JSON disassembly makes the file inspectable without booting the VM.
        struct Disasm: Encodable {
            let textCount: Int
            let entryCount: Int
            let instructionCount: Int
            let entryPoints: [UInt16]
            let texts: [String]
            let instructions: [Line]
            struct Line: Encodable {
                let word: Int
                let opcode: String
                let parameter: Int
                let raw: String
            }
        }
        var currentWord = 0
        var lines: [Disasm.Line] = []
        lines.reserveCapacity(program.instructions.count)
        for insn in program.instructions {
            lines.append(Disasm.Line(
                word: currentWord,
                opcode: String(describing: insn.opcode),
                parameter: insn.parameter,
                raw: String(format: "%04X", insn.rawWord)
            ))
            currentWord += insn.wordSize
        }
        let disasm = Disasm(
            textCount: program.texts.count,
            entryCount: program.entryPoints.count,
            instructionCount: program.instructions.count,
            entryPoints: program.entryPoints,
            texts: program.texts,
            instructions: lines
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(disasm).write(to: dir.appendingPathComponent("\(name).json"))
    }

    // MARK: Passthrough

    /// Copies raw bytes under a category folder without decoding. Used for
    /// formats whose decoders are out of scope for P1 (XMI/ADL/C55/EMC/INI).
    public static func passthrough(name: String, data: Data, category: String, ctx: ExtractContext) throws {
        let dir = ctx.dir(category)
        try data.write(to: dir.appendingPathComponent(name))
    }
}
