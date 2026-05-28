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
                        Section("\(category.title) — \(category.assets.count)") {
                            ForEach(category.assets) { asset in
                                Text(asset.displayName)
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
    struct RawFrame {
        let indices: [UInt8]
        let width: Int
        let height: Int
        let hasLookup: Bool
    }

    enum RemapKind {
        case none
        case sprite
        case tile
    }

    @Environment(AssetLibrary.self) private var library

    let asset: AssetLibrary.Asset
    let house: House
    let scale: Int
    let fps: Double

    @State private var rawFrames: [RawFrame] = []
    @State private var displayPalette: Palette?
    @State private var transparentIndex: Int?
    @State private var remapKind: RemapKind = .none
    @State private var paletteAnimatable = false
    @State private var sound: Voc.Sound?
    @State private var scriptText: String?
    @State private var info = ""

    @State private var startDate = Date()
    @State private var isPlaying = false
    @State private var frameIndex = 0
    @State private var animatePalette = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(info).font(.callout).foregroundStyle(.secondary)

                if !rawFrames.isEmpty {
                    GroupBox {
                        previewSection
                    } label: {
                        Text("Preview — \(rawFrames.count) frame\(rawFrames.count == 1 ? "" : "s")")
                    }
                    if rawFrames.count > 1 {
                        GroupBox("All frames") { framesGrid }
                    }
                }
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
        .onChange(of: isPlaying) { _, playing in if playing { startDate = Date() } }
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if canPlay {
                    Toggle(isOn: $isPlaying) {
                        Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .toggleStyle(.button)
                }

                if (!isPlaying || !canPlay), rawFrames.count > 1 {
                    Stepper("\(stepLabel) \(currentFrame) / \(rawFrames.count - 1)", value: $frameIndex, in: 0 ... (rawFrames.count - 1))
                        .fixedSize()
                }
                if paletteAnimatable {
                    Toggle("Palette cycling", isOn: $animatePalette).toggleStyle(.switch)
                }
                Spacer()
            }
            preview
        }
    }

    private var currentFrame: Int { min(max(frameIndex, 0), max(rawFrames.count - 1, 0)) }

    // Directional groups are facing-selected, not time-animated — no Play, just a facing stepper.
    private var canPlay: Bool { asset.groupKind != .directional }
    private var stepLabel: String { asset.groupKind == .directional ? "Facing" : "Frame" }

    @ViewBuilder
    private var preview: some View {
        if (isPlaying && canPlay) || (paletteAnimatable && animatePalette) {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(startDate)
                let tick = max(Int(elapsed * 60), 0)
                let index = (isPlaying && canPlay && rawFrames.count > 1) ? Int(elapsed * fps) % rawFrames.count : currentFrame
                previewImage(frame: index, tick: tick)
            }
        } else {
            previewImage(frame: currentFrame, tick: 0)
        }
    }

    @ViewBuilder
    private func previewImage(frame: Int, tick: Int) -> some View {
        let raw = rawFrames[min(max(frame, 0), rawFrames.count - 1)]
        if let image = colorize(raw, palette: previewPalette(tick: tick)) {
            scaled(image)
        } else {
            Color.clear.frame(width: 64, height: 64)
        }
    }

    private var framesGrid: some View {
        LazyVGrid(columns: [ GridItem(.adaptive(minimum: 80), spacing: 12) ], spacing: 12) {
            ForEach(rawFrames.indices, id: \.self) { index in
                let raw = rawFrames[index]
                VStack(spacing: 4) {
                    if let image = colorize(raw, palette: displayPalette ?? library.palette) {
                        thumbnail(image)
                    }
                    Text("\(index) · \(raw.width)×\(raw.height)").font(.caption2).foregroundStyle(.secondary)
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
        let thumbScale = scale
        return Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: CGFloat(image.width * thumbScale), height: CGFloat(image.height * thumbScale))
            .background(Color(white: 0.15))
    }

    // MARK: - Colorizing (house remap + palette cycling apply live here)

    private func previewPalette(tick: Int) -> Palette {
        let base = displayPalette ?? library.palette
        return (paletteAnimatable && animatePalette) ? PaletteAnimator.animatedPalette(base: base, tick: tick) : base
    }

    /// Mentat face sprites (MENSHP[H/A/O/M].SHP) are colored by the matching MENTAT<house>.CPS
    /// palette, not IBM.PAL (OpenDUNE `gui/mentat.c:494`).
    private func mentatPalette(for name: String) -> Palette? {
        let upper = name.uppercased()
        guard upper.hasPrefix("MENSHP"), upper.hasSuffix(".SHP"), upper.count > 6 else { return nil }

        let letter = upper[upper.index(upper.startIndex, offsetBy: 6)]
        return library.cpsPalette("MENTAT\(letter).CPS")
    }

    private func colorize(_ frame: RawFrame, palette: Palette) -> CGImage? {
        let useSprite = remapKind == .sprite && frame.hasLookup
        let remap: (UInt8) -> UInt8 = { index in
            if remapKind == .tile { return HouseRemap.tile(index, house: house) }
            if useSprite { return HouseRemap.sprite(index, house: house) }
            return index
        }
        return IndexedImage.cgImage(
            indices: frame.indices, width: frame.width, height: frame.height,
            palette: palette, transparentIndex: transparentIndex, remap: remap
        )
    }

    // MARK: - Decode

    private func decode() {
        rawFrames = []
        displayPalette = nil
        transparentIndex = nil
        remapKind = .none
        paletteAnimatable = false
        sound = nil
        scriptText = nil
        isPlaying = false
        frameIndex = 0
        startDate = Date()

        guard let data = library.data(for: asset) else { info = "(asset data missing)"; return }

        switch asset.kind {
            case .sprite:
                guard let set = try? Shp.FrameSet(data) else { info = "(SHP decode failed)"; return }
                let selected = asset.frameRange.map { Array(set.frames[$0.clamped(to: set.frames.indices)]) } ?? set.frames
                rawFrames = selected.compactMap { frame in
                    frame.width > 0 && frame.height > 0
                        ? RawFrame(indices: frame.pixels, width: frame.width, height: frame.height, hasLookup: frame.hasLookup)
                        : nil
                }
                transparentIndex = 0
                remapKind = .sprite
                paletteAnimatable = true
                displayPalette = mentatPalette(for: asset.name)   // mentat faces use their MENTAT<house>.CPS palette
                let kindLabel = asset.groupKind.map { $0 == .animation ? " · animation" : " · directional" } ?? ""
                info = "\(selected.count) frames\(kindLabel)"
            case .image:
                guard let image = try? Cps.decode(data) else { info = "(CPS decode failed)"; return }
                rawFrames = [ RawFrame(indices: image.pixels, width: image.width, height: image.height, hasLookup: false) ]
                displayPalette = image.palette
                paletteAnimatable = true
                info = "\(image.width)×\(image.height)"
            case .tiles:
                guard let tiles = try? Icn.TileSet(data) else { info = "(ICN decode failed)"; return }
                let sheet = tileSheet(tiles)
                rawFrames = [ RawFrame(indices: sheet.indices, width: sheet.width, height: sheet.height, hasLookup: false) ]
                remapKind = .tile
                paletteAnimatable = true
                info = "\(tiles.tileCount) tiles · \(tiles.tileWidth)×\(tiles.tileHeight) (16 per row)"
            case .animation:
                guard let animation = try? Wsa.Animation(data) else { info = "(WSA decode failed)"; return }
                rawFrames = animation.frames.map {
                    RawFrame(indices: $0, width: animation.width, height: animation.height, hasLookup: false)
                }
                displayPalette = animation.palette
                paletteAnimatable = true
                info = "\(animation.frames.count) frames · \(animation.width)×\(animation.height)"
            case .font:
                guard let font = try? Fnt.Font(data) else { info = "(FNT decode failed)"; return }
                let sheet = fontSheet(font)
                rawFrames = [ RawFrame(indices: sheet.indices, width: sheet.width, height: sheet.height, hasLookup: false) ]
                displayPalette = AssetDetailView.monochrome
                transparentIndex = 0
                info = "\(font.glyphs.count) glyphs · height \(font.height)"
            case .sound:
                sound = try? Voc.decode(data)
                info = sound.map { "\($0.sampleRate) Hz · \($0.samples.count) samples" } ?? "(VOC decode failed)"
            case .script:
                scriptText = (try? Emc.Program(data)).map { emcText($0) }
                info = "EMC script"
            case .iconGroup:
                guard
                    let tiles = try? Icn.TileSet(data),
                    let mapData = library.data(pak: asset.pak, name: "ICON.MAP"),
                    let iconMap = try? IconMap(mapData),
                    let index = asset.iconGroup,
                    let group = iconMap.group(index)
                else { info = "(icon group decode failed)"; return }
                rawFrames = group.tileIDs.compactMap { tileID in
                    let pixels = tiles.tile(tileID)
                    return pixels.isEmpty ? nil : RawFrame(indices: pixels, width: tiles.tileWidth, height: tiles.tileHeight, hasLookup: false)
                }
                remapKind = .tile
                paletteAnimatable = true
                info = "\(group.name) · \(rawFrames.count) tiles"
        }
    }

    private func tileSheet(_ tiles: Icn.TileSet) -> (indices: [UInt8], width: Int, height: Int) {
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

    private func fontSheet(_ font: Fnt.Font) -> (indices: [UInt8], width: Int, height: Int) {
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
        return (indices, width, height)
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
