import CoreGraphics
import DuneIIFormats
import DuneIIRenderer
import SwiftUI

struct ContentView: View {
    @Environment(AssetLibrary.self) private var library
    @State private var selection: AssetLibrary.Asset?
    @State private var house: House = .harkonnen
    @State private var scale = 2
    @State private var fps = 10.0

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .toolbar { toolbar }
                .navigationTitle(selection?.name ?? "Render Test")
        }
    }

    private var sidebar: some View {
        Group {
            if let error = library.loadError {
                ContentUnavailableView("Install not found", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                List(selection: $selection) {
                    ForEach(library.categories) { category in
                        Section("\(category.kind.rawValue) — \(category.assets.count)") {
                            ForEach(category.assets) { asset in
                                Text(asset.name)
                                    .font(.system(.body, design: .monospaced))
                                    .tag(asset)
                            }
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
    }

    @ViewBuilder
    private var detail: some View {
        if let selection {
            AssetDetailView(asset: selection, house: house, scale: scale, fps: fps)
                .id(selection.id)
        } else {
            ContentUnavailableView("Select an asset", systemImage: "photo.on.rectangle.angled")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("House", selection: $house) {
                ForEach(House.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)

            Picker("Scale", selection: $scale) {
                ForEach([ 1, 2, 4, 8, 16 ], id: \.self) { Text("\($0)×").tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Image(systemName: "speedometer")
                Slider(value: $fps, in: 1 ... 30) { Text("FPS") }.frame(width: 120)
                Text("\(Int(fps)) fps").monospacedDigit().frame(width: 52, alignment: .leading)
            }
        }
    }
}

struct AssetDetailView: View {
    @Environment(AssetLibrary.self) private var library

    let asset: AssetLibrary.Asset
    let house: House
    let scale: Int
    let fps: Double

    @State private var frames: [CGImage] = []
    @State private var sheet: CGImage?
    @State private var sound: Voc.Sound?
    @State private var scriptText: String?
    @State private var info = ""
    @State private var startDate = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(info).font(.callout).foregroundStyle(.secondary)

                if !frames.isEmpty {
                    GroupBox("Animated (\(Int(fps)) fps)") { animatedPreview }
                    GroupBox("All frames") { framesGrid }
                }
                if let sheet { GroupBox("Image") { scaled(sheet) } }
                if let sound { GroupBox("Sound") { soundView(sound) } }
                if let scriptText {
                    GroupBox("Disassembly") {
                        Text(scriptText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .task(id: asset.id) { decode() }
        .onChange(of: house) { _, _ in decode() }
    }

    // MARK: - Subviews

    private var animatedPreview: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let index = frames.isEmpty ? 0 : Int(elapsed * fps) % frames.count
            scaled(frames[index])
        }
    }

    private var framesGrid: some View {
        LazyVGrid(columns: [ GridItem(.adaptive(minimum: 72), spacing: 12) ], spacing: 12) {
            ForEach(Array(frames.enumerated()), id: \.offset) { index, image in
                VStack(spacing: 4) {
                    thumbnail(image)
                    Text("\(index)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func soundView(_ sound: Voc.Sound) -> some View {
        HStack(spacing: 16) {
            Button {
                library.playSound(sound)
            } label: {
                Label("Play", systemImage: "play.circle.fill")
            }
            Text("\(sound.sampleRate) Hz · \(sound.samples.count) samples")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scaled(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: CGFloat(image.width * scale), height: CGFloat(image.height * scale))
            .background(Color(white: 0.15))
            .border(Color.gray.opacity(0.4))
    }

    private func thumbnail(_ image: CGImage) -> some View {
        let thumbScale = min(scale, 2)
        return Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: CGFloat(image.width * thumbScale), height: CGFloat(image.height * thumbScale))
            .background(Color(white: 0.15))
    }

    // MARK: - Decode

    private func decode() {
        frames = []
        sheet = nil
        sound = nil
        scriptText = nil
        startDate = Date()

        guard let data = library.data(for: asset) else { info = "(asset data missing)"; return }

        switch asset.kind {
            case .sprite:
                guard let set = try? Shp.FrameSet(data) else { info = "(SHP decode failed)"; return }
                frames = set.frames.compactMap { frame in
                    guard frame.width > 0, frame.height > 0 else { return nil }

                    let remap: (UInt8) -> UInt8 = frame.hasLookup ? { HouseRemap.sprite($0, house: house) } : { $0 }
                    return IndexedImage.cgImage(
                        indices: frame.pixels, width: frame.width, height: frame.height,
                        palette: library.palette, transparentIndex: 0, remap: remap
                    )
                }
                info = "\(set.frames.count) frames"
            case .image:
                guard let image = try? Cps.decode(data) else { info = "(CPS decode failed)"; return }
                sheet = IndexedImage.cgImage(
                    indices: image.pixels, width: image.width, height: image.height,
                    palette: image.palette ?? library.palette
                )
                info = "\(image.width)×\(image.height)"
            case .tiles:
                guard let tiles = try? Icn.TileSet(data) else { info = "(ICN decode failed)"; return }
                sheet = tileSheet(tiles)
                info = "\(tiles.tileCount) tiles · \(tiles.tileWidth)×\(tiles.tileHeight) (16 per row)"
            case .animation:
                guard let animation = try? Wsa.Animation(data) else { info = "(WSA decode failed)"; return }
                let palette = animation.palette ?? library.palette
                frames = animation.frames.compactMap {
                    IndexedImage.cgImage(indices: $0, width: animation.width, height: animation.height, palette: palette)
                }
                info = "\(animation.frames.count) frames · \(animation.width)×\(animation.height)"
            case .font:
                guard let font = try? Fnt.Font(data) else { info = "(FNT decode failed)"; return }
                sheet = fontSheet(font)
                info = "\(font.glyphs.count) glyphs · height \(font.height)"
            case .sound:
                sound = try? Voc.decode(data)
                info = sound.map { "\($0.sampleRate) Hz · \($0.samples.count) samples" } ?? "(VOC decode failed)"
            case .script:
                scriptText = (try? Emc.Program(data)).map { emcText($0) }
                info = "EMC script"
        }
    }

    private func tileSheet(_ tiles: Icn.TileSet) -> CGImage? {
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
        return IndexedImage.cgImage(
            indices: indices, width: width, height: height,
            palette: library.palette, remap: { HouseRemap.tile($0, house: house) }
        )
    }

    private func fontSheet(_ font: Fnt.Font) -> CGImage? {
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
                    if px < width, py < height { indices[py * width + px] = 1 }   // set -> white
                }
            }
        }
        return IndexedImage.cgImage(
            indices: indices, width: width, height: height,
            palette: AssetDetailView.monochrome, transparentIndex: 0
        )
    }

    private func emcText(_ program: Emc.Program) -> String {
        let upper = asset.name.uppercased()
        let kind: Emc.ObjectKind = upper.contains("BUILD") ? .structure : (upper.contains("TEAM") ? .team : .unit)
        var lines: [String] = []
        for typeIndex in program.offsets.indices {
            let instructions = Emc.disassemble(program, typeIndex: typeIndex, kind: kind)
            guard !instructions.isEmpty else { continue }

            lines.append("; ---- type \(typeIndex) ----")
            for instruction in instructions {
                var line = "\(instruction.address):  \(instruction.name)"
                if let operand = instruction.operand { line += " \(operand)" }
                if let functionName = instruction.functionName { line += "  ; \(functionName)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A 2-entry palette (index 1 = white) for rendering font glyphs as white-on-transparent.
    static let monochrome: Palette = {
        var bytes = [UInt8](repeating: 0, count: 768)
        bytes[3] = 63
        bytes[4] = 63
        bytes[5] = 63
        return try! Palette(Data(bytes))
    }()
}
