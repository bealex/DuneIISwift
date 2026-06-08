import CoreGraphics
import DuneIIFormats
import DuneIIRenderer
import SwiftUI

struct ContentView: View {
    @Environment(AssetLibrary.self)
    private var library
    @State
    private var selection: AssetLibrary.Asset?
    @State
    private var house: House = .harkonnen
    @State
    private var scale = 2
    @State
    private var fps = 10.0
    @State
    private var collapsed: Set<String> = []  // category ids the user has collapsed

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
                ContentUnavailableView(
                    "Install not found",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                List(selection: $selection) {
                    ForEach(library.categories) { category in
                        Section(isExpanded: expansion(category.id)) {
                            ForEach(category.assets) { asset in
                                Text(asset.displayName)
                                    .font(.system(.body, design: .monospaced))
                                    .tag(asset)
                            }
                        } header: {
                            Text("\(category.title) — \(category.assets.count)")
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
    }

    /// A binding driving one category's disclosure state (expanded unless the user collapsed it).
    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { isExpanded in if isExpanded { collapsed.remove(id) } else { collapsed.insert(id) } }
        )
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
    @Environment(AssetLibrary.self)
    private var library

    let asset: AssetLibrary.Asset
    let house: House
    let scale: Int
    let fps: Double

    @State
    private var rawFrames: [RawFrame] = []
    @State
    private var displayPalette: Palette?
    @State
    private var transparentIndex: Int?
    @State
    private var remapKind: RemapKind = .none
    @State
    private var paletteAnimatable = false
    @State
    private var sound: Voc.Sound?
    @State
    private var scriptText: String?
    @State
    private var info = ""

    @State
    private var startDate = Date()
    @State
    private var isPlaying = false
    @State
    private var frameIndex = 0
    @State
    private var animatePalette = true

    @State
    private var musicPlaying = false
    @State
    private var musicLoop = true

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
                if let music = asset.music {
                    GroupBox("AdLib FM (OPL3) preview") { musicView(file: music.file, song: music.song) }
                }
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
        .onDisappear { library.stopMusic() }
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
                    Stepper(
                        "\(stepLabel) \(currentFrame) / \(rawFrames.count - 1)",
                        value: $frameIndex,
                        in: 0 ... (rawFrames.count - 1)
                    )
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
                let index =
                    (isPlaying && canPlay && rawFrames.count > 1) ? Int(elapsed * fps) % rawFrames.count : currentFrame
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
        LazyVGrid(
            columns: [ GridItem(.adaptive(minimum: 80), spacing: 12, alignment: .top) ],
            alignment: .leading,
            spacing: 12
        ) {
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
        // Span the whole detail pane so `.adaptive` packs as many thumbnails per row as fit; without this the
        // grid is the only non-greedy block here and collapses to its content width.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func musicView(file: Int, song: Int) -> some View {
        HStack(spacing: 16) {
            Button {
                library.playMusic(file: file, song: song, loop: musicLoop)
                musicPlaying = true
            } label: {
                Label(musicPlaying ? "Restart" : "Play", systemImage: "play.circle.fill")
            }
            Button {
                library.stopMusic()
                musicPlaying = false
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
            .disabled(!musicPlaying)
            Toggle("Loop", isOn: $musicLoop).toggleStyle(.switch)
            Text("DUNE\(file).ADL · song \(song)").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func colorize(_ frame: RawFrame, palette: Palette) -> CGImage? {
        let useSprite = remapKind == .sprite && frame.hasLookup
        let remap: (UInt8) -> UInt8 = { index in
            if remapKind == .tile { return HouseRemap.tile(index, house: house) }
            if useSprite { return HouseRemap.sprite(index, house: house) }
            return index
        }
        return IndexedImage.cgImage(
            indices: frame.indices,
            width: frame.width,
            height: frame.height,
            palette: palette,
            transparentIndex: transparentIndex,
            remap: remap
        )
    }

    // MARK: - Decode

    private func decode() {
        // Reset the view's own preview/animation state, then pull the content from the decoder (which owns
        // every per-format branch + sheet/structure assembly — see `AssetDecoder`).
        isPlaying = false
        startDate = Date()
        library.stopMusic()  // selecting any asset stops a music preview that was playing
        musicPlaying = false

        let decoded = AssetDecoder(library: library).decode(asset)
        rawFrames = decoded.rawFrames
        displayPalette = decoded.displayPalette
        transparentIndex = decoded.transparentIndex
        remapKind = decoded.remapKind
        paletteAnimatable = decoded.paletteAnimatable
        sound = decoded.sound
        scriptText = decoded.scriptText
        info = decoded.info
        frameIndex = decoded.initialFrameIndex
    }
}
