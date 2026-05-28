import DuneIIExport
import DuneIIFormats
import Foundation

// Dune II asset tool.
//   assetgen emc-disasm <file.EMC> [unit|structure|team]
//   assetgen extract <installDir> <outputDir>     -- decode install PAKs to PNG / WAV / text for verification

func usage() {
    print("usage:")
    print("  assetgen emc-disasm <file.EMC> [unit|structure|team]")
    print("  assetgen extract <installDir> <outputDir>")
}

// MARK: - emc-disasm

func objectKind(path: String, override: String?) -> Emc.ObjectKind {
    if let override = override?.lowercased() {
        if override.hasPrefix("s") || override.hasPrefix("b") { return .structure }
        if override.hasPrefix("t") { return .team }
        return .unit
    }

    let name = (path as NSString).lastPathComponent.uppercased()
    if name.contains("BUILD") { return .structure }
    if name.contains("TEAM") { return .team }
    return .unit
}

func emcListing(_ program: Emc.Program, kind: Emc.ObjectKind) -> String {
    var lines: [String] = []
    for typeIndex in program.offsets.indices {
        let instructions = Emc.disassemble(program, typeIndex: typeIndex, kind: kind)
        guard !instructions.isEmpty else { continue }

        lines.append("; ---- type \(typeIndex) (entry @\(program.offsets[typeIndex])) ----")
        for instruction in instructions {
            var line = String(format: "%5d:  %@", instruction.address, instruction.name)
            if let operand = instruction.operand { line += " \(operand)" }
            if let functionName = instruction.functionName { line += "  ; \(functionName)" }
            lines.append(line)
        }
    }
    return lines.joined(separator: "\n")
}

func runEmcDisasm(_ arguments: [String]) {
    guard let path = arguments.first, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        usage()
        exit(1)
    }

    do {
        let program = try Emc.Program(data)
        print(emcListing(program, kind: objectKind(path: path, override: arguments.count >= 2 ? arguments[1] : nil)))
    } catch {
        print("assetgen: emc-disasm failed: \(error)")
        exit(1)
    }
}

// MARK: - extract

func makeDirectory(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

func defaultPalette(_ installDir: URL) -> Palette {
    if
        let data = try? Data(contentsOf: installDir.appendingPathComponent("DUNE.PAK")),
        let archive = try? Pak.Archive(data),
        let paletteData = archive.data(named: "IBM.PAL"),
        let palette = try? Palette(paletteData)
    {
        return palette
    }

    print("assetgen: IBM.PAL not found in DUNE.PAK — exporting with a grayscale palette")
    return grayscalePalette()
}

func grayscalePalette() -> Palette {
    var bytes = [UInt8](repeating: 0, count: 768)
    for index in 0 ..< 256 {
        let value = UInt8(index >> 2)
        bytes[index * 3] = value
        bytes[index * 3 + 1] = value
        bytes[index * 3 + 2] = value
    }
    return try! Palette(Data(bytes))
}

func extractEntry(
    _ data: Data, name: String, into directory: URL, palette: Palette, grayscale: Palette, counts: inout [String: Int]
) {
    let base = (name as NSString).deletingPathExtension
    let kind = (name as NSString).pathExtension.uppercased()
    do {
        switch kind {
            case "SHP":
                let set = try Shp.FrameSet(data)
                let folder = directory.appendingPathComponent("Sprites/\(base)")
                makeDirectory(folder)
                for (index, frame) in set.frames.enumerated() where frame.width > 0 {
                    let url = folder.appendingPathComponent(String(format: "frame%03d.png", index))
                    try PngWriter.write(
                        indices: frame.pixels, width: frame.width, height: frame.height,
                        palette: palette, transparentIndex: 0, to: url
                    )
                }
                counts["SHP", default: 0] += 1
            case "CPS":
                let image = try Cps.decode(data)
                let folder = directory.appendingPathComponent("Images")
                makeDirectory(folder)
                try PngWriter.write(
                    indices: image.pixels, width: image.width, height: image.height,
                    palette: image.palette ?? palette, to: folder.appendingPathComponent("\(base).png")
                )
                counts["CPS", default: 0] += 1
            case "ICN":
                let tiles = try Icn.TileSet(data)
                let sheet = tileSheet(tiles)
                let folder = directory.appendingPathComponent("Tiles")
                makeDirectory(folder)
                try PngWriter.write(
                    indices: sheet.indices, width: sheet.width, height: sheet.height,
                    palette: palette, to: folder.appendingPathComponent("\(base).png")
                )
                counts["ICN", default: 0] += 1
            case "WSA":
                let animation = try Wsa.Animation(data)
                let folder = directory.appendingPathComponent("Animations/\(base)")
                makeDirectory(folder)
                for (index, frame) in animation.frames.enumerated() where animation.width > 0 {
                    let url = folder.appendingPathComponent(String(format: "frame%03d.png", index))
                    try PngWriter.write(
                        indices: frame, width: animation.width, height: animation.height,
                        palette: animation.palette ?? palette, to: url
                    )
                }
                counts["WSA", default: 0] += 1
            case "VOC":
                let sound = try Voc.decode(data)
                let folder = directory.appendingPathComponent("Audio")
                makeDirectory(folder)
                try WavWriter.write(
                    samples: sound.samples, sampleRate: max(sound.sampleRate, 1),
                    to: folder.appendingPathComponent("\(base).wav")
                )
                counts["VOC", default: 0] += 1
            case "EMC":
                let program = try Emc.Program(data)
                let folder = directory.appendingPathComponent("Scripts")
                makeDirectory(folder)
                let listing = emcListing(program, kind: objectKind(path: name, override: nil))
                try listing.write(to: folder.appendingPathComponent("\(base).emc.txt"), atomically: true, encoding: .utf8)
                counts["EMC", default: 0] += 1
            case "FNT":
                let font = try Fnt.Font(data)
                let sheet = fontSheet(font)
                let folder = directory.appendingPathComponent("Fonts")
                makeDirectory(folder)
                try PngWriter.write(
                    indices: sheet.indices, width: sheet.width, height: sheet.height,
                    palette: grayscale, transparentIndex: 0, to: folder.appendingPathComponent("\(base).png")
                )
                counts["FNT", default: 0] += 1
            default:
                break
        }
    } catch {
        counts["failed", default: 0] += 1
    }
}

func tileSheet(_ tiles: Icn.TileSet) -> (indices: [UInt8], width: Int, height: Int) {
    let perRow = 16
    let rows = max((tiles.tileCount + perRow - 1) / perRow, 1)
    let width = tiles.tileWidth * perRow
    let height = tiles.tileHeight * rows
    var indices = [UInt8](repeating: 0, count: width * height)
    for tile in 0 ..< tiles.tileCount {
        let pixels = tiles.tile(tile)
        let originX = (tile % perRow) * tiles.tileWidth
        let originY = (tile / perRow) * tiles.tileHeight
        for y in 0 ..< tiles.tileHeight {
            for x in 0 ..< tiles.tileWidth {
                let source = y * tiles.tileWidth + x
                if source < pixels.count { indices[(originY + y) * width + originX + x] = pixels[source] }
            }
        }
    }
    return (indices, width, height)
}

func fontSheet(_ font: Fnt.Font) -> (indices: [UInt8], width: Int, height: Int) {
    let perRow = 16
    let cellWidth = max(font.maxWidth, 1)
    let cellHeight = max(font.height, 1)
    let rows = max((font.glyphs.count + perRow - 1) / perRow, 1)
    let width = cellWidth * perRow
    let height = cellHeight * rows
    var indices = [UInt8](repeating: 0, count: width * height)
    for (glyphIndex, glyph) in font.glyphs.enumerated() {
        let originX = (glyphIndex % perRow) * cellWidth
        let originY = (glyphIndex / perRow) * cellHeight + glyph.topRows
        for y in 0 ..< glyph.bitmapRows {
            for x in 0 ..< glyph.width {
                let source = y * glyph.width + x
                guard source < glyph.pixels.count, glyph.pixels[source] != 0 else { continue }

                let px = originX + x
                let py = originY + y
                if px < width, py < height { indices[py * width + px] = 255 }   // set pixels -> white
            }
        }
    }
    return (indices, width, height)
}

func runExtract(_ arguments: [String]) {
    guard arguments.count >= 2 else { usage(); exit(1) }

    let installDir = URL(fileURLWithPath: arguments[0])
    let outputDir = URL(fileURLWithPath: arguments[1])
    let palette = defaultPalette(installDir)
    let grayscale = grayscalePalette()

    guard let entries = try? FileManager.default.contentsOfDirectory(at: installDir, includingPropertiesForKeys: nil) else {
        print("assetgen: cannot list \(installDir.path)")
        exit(1)
    }

    let paks = entries.filter { $0.pathExtension.uppercased() == "PAK" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    var counts: [String: Int] = [:]
    for pak in paks {
        guard let data = try? Data(contentsOf: pak), let archive = try? Pak.Archive(data) else { continue }

        let directory = outputDir.appendingPathComponent(pak.deletingPathExtension().lastPathComponent)
        for entry in archive.entries {
            extractEntry(
                archive.data(entry), name: entry.name, into: directory,
                palette: palette, grayscale: grayscale, counts: &counts
            )
        }
    }

    print("extracted to \(outputDir.path):")
    for (kind, count) in counts.sorted(by: { $0.key < $1.key }) {
        print("  \(kind): \(count)")
    }
}

// MARK: - dispatch

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("assetgen — Dune II asset tool")
    usage()
    exit(0)
}

switch command {
    case "emc-disasm":
        runEmcDisasm(Array(arguments.dropFirst()))
    case "extract":
        runExtract(Array(arguments.dropFirst()))
    default:
        print("assetgen: unknown command '\(command)'")
        usage()
        exit(1)
}
