import CoreGraphics
import DuneIIContracts
import DuneIIFormats
import DuneIIRenderer
import DuneIISimulation
import DuneIIWorld
import SwiftUI

// MARK: - Sprite rendering

/// Renders a `UnitType`/`StructureType` (house-recoloured) to a `CGImage` for the sidebar, caching the
/// result per (type, house). Units use their north-facing body sprite (`UnitInfo.groundSpriteID` → the
/// `GlobalSprite` load-order map → an `UNITS*.SHP` frame); buildings are assembled from their `ICON.ICN`
/// tiles at the completed build state — the same paths the render-test app uses.
@MainActor final class SpriteImageProvider {
    private struct Key: Hashable { let objectType: UInt16; let isStructure: Bool; let house: Int }
    private var cache: [Key: CGImage] = [:]

    func image(objectType: UInt16, isStructure: Bool, house: HouseID, assets: AssetStore) -> CGImage? {
        let key = Key(objectType: objectType, isStructure: isStructure, house: house.rawValue)
        if let cached = cache[key] { return cached }
        let image = isStructure
            ? Self.structureImage(objectType, house: house, assets: assets)
            : Self.unitImage(objectType, house: house, assets: assets)
        if let image { cache[key] = image }
        return image
    }

    private var wsaCache: [String: CGImage?] = [:]

    /// The Mentat picture for a help topic: the first frame of its `*.WSA` (from `MENTAT.PAK`), decoded once
    /// and cached (misses cached too). This is the image the original Mentat shows for each topic
    /// (`GUI_Mentat_Loop`'s `WSA_LoadFile`) — used instead of our composed unit/structure sprite. nil ⇒ the
    /// caller falls back to a sprite.
    func wsaImage(name: String, assets: AssetStore) -> CGImage? {
        if let cached = wsaCache[name] { return cached }

        let image: CGImage? = {
            guard
                let data = assets.data(name),
                let anim = try? Wsa.Animation(data),
                let frame = anim.frames.first
            else { return nil }

            return Minimap.rgbaImage(
                indices: frame,
                width: anim.width,
                height: anim.height,
                palette: anim.palette ?? assets.palette
            )
        }()
        wsaCache[name] = image
        return image
    }

    private struct DecodedFrame { let pixels: [UInt8]; let w: Int; let h: Int; let hasLookup: Bool }

    private static func unitFrame(_ globalIndex: Int, assets: AssetStore) -> DecodedFrame? {
        guard
            let (sheet, frame) = GlobalSprite.unit(globalIndex),
            let set = assets.shp(sheet.fileName),
            frame >= 0,
            frame < set.frames.count
        else { return nil }

        let f = set.frames[frame]
        return DecodedFrame(pixels: f.pixels, w: f.width, h: f.height, hasLookup: f.hasLookup)
    }

    private static func unitImage(_ objectType: UInt16, house: HouseID, assets: AssetStore) -> CGImage? {
        guard let type = UnitType(rawValue: Int(objectType)) else { return nil }

        let info = UnitInfo[type]
        let remapHouse = DuneIIRenderer.House(rawValue: house.rawValue) ?? .harkonnen

        // House recolour, gated by the frame's lookup flag (a frame without house pixels passes through).
        func resolve(_ idx: UInt8, _ hasLookup: Bool) -> UInt8 {
            hasLookup ? HouseRemap.sprite(idx, house: remapHouse) : idx
        }

        // North-facing (orientation 0): the body frame is `groundSpriteID` for every display mode
        // (`UnitSprites.info` adds 0 at orientation 0 for directional/infantry/air alike).
        guard let body = unitFrame(Int(info.groundSpriteID), assets: assets) else { return nil }
        // Units with a turret (tanks, launcher, sonic, deviator, …) composite it on top at its
        // orientation-0 pixel offset (`UnitSprites.turretOffset`, `viewport.c`).
        guard
            info.turretSpriteID != 0xFFFF,
            let turret = unitFrame(Int(info.turretSpriteID), assets: assets)
        else {
            return IndexedImage.cgImage(
                indices: body.pixels,
                width: body.w,
                height: body.h,
                palette: assets.palette,
                transparentIndex: 0,
                remap: { resolve($0, body.hasLookup) }
            )
        }

        let (tdx, tdy) = turretOffset0(info.turretSpriteID)
        // Bounding box of body (centred) + turret (centred + offset) so the gun barrel isn't clipped.
        let bx0 = -body.w / 2, by0 = -body.h / 2
        let tx0 = tdx - turret.w / 2, ty0 = tdy - turret.h / 2
        let minX = min(bx0, tx0), minY = min(by0, ty0)
        let cw = max(bx0 + body.w, tx0 + turret.w) - minX, ch = max(by0 + body.h, ty0 + turret.h) - minY
        guard cw > 0, ch > 0 else { return nil }

        var canvas = [UInt8](repeating: 0, count: cw * ch)

        func blit(_ f: DecodedFrame, atX ox: Int, atY oy: Int) {
            for y in 0 ..< f.h {
                for x in 0 ..< f.w {
                    let s = y * f.w + x
                    guard s < f.pixels.count else { continue }

                    let idx = f.pixels[s]
                    if idx == 0 { continue }  // transparent
                    canvas[(oy + y) * cw + (ox + x)] = resolve(idx, f.hasLookup)
                }
            }
        }

        blit(body, atX: bx0 - minX, atY: by0 - minY)
        blit(turret, atX: tx0 - minX, atY: ty0 - minY)  // gun on top
        return IndexedImage.cgImage(
            indices: canvas,
            width: cw,
            height: ch,
            palette: assets.palette,
            transparentIndex: 0,
            remap: { $0 }
        )  // already house-resolved
    }

    /// Orientation-0 turret pixel offset — the north-facing slice of `UnitSprites.turretOffset` (`viewport.c`).
    private static func turretOffset0(_ turretSpriteID: UInt16) -> (Int, Int) {
        return switch turretSpriteID {
            case 141: (0, -2)  // sonic tank
            case 146: (0, -3)  // launcher / deviator
            case 126: (0, -5)  // siege tank
            case 136: (0, -4)  // devastator
            default: (0, 0)  // combat tank, …
        }
    }

    private static func structureImage(_ objectType: UInt16, house: HouseID, assets: AssetStore) -> CGImage? {
        guard
            let type = StructureType(rawValue: Int(objectType)),
            let tiles = assets.tileSet,
            let iconMap = assets.iconMap
        else { return nil }

        let groupIndex = Int(StructureInfo[type].iconGroup)
        guard let group = iconMap.group(groupIndex), let first = group.tileIDs.first else { return nil }

        // The structure's footprint in tiles (from its layout) — works for every group, including the special
        // 1×1 ones (walls = group 6, concrete = group 8, turrets = 23/24) that aren't in `StructureCatalog`.
        let layout = StructureLayoutInfo[StructureInfo[type].layout].size
        let w = max(1, Int(layout.width)), h = max(1, Int(layout.height))
        let perState = w * h

        let remapHouse = DuneIIRenderer.House(rawValue: house.rawValue) ?? .harkonnen
        // House recolour, then neutralise the palette-cycling placeholders (IBM.PAL indices 223 wind-trap /
        // 239 repair / 255 selection render as magenta without animation) → black, per the user's request.
        let remap: (UInt8) -> UInt8 = { idx in
            (idx == 223 || idx == 239 || idx == 255) ? 0 : HouseRemap.tile(idx, house: remapHouse)
        }
        let tw = tiles.tileWidth, th = tiles.tileHeight

        // Concrete slabs (1×1 and 2×2) share the 1×1 concrete icon group (group 8), so the generic per-state
        // layout maths below overruns the group's tile list for the 2×2 and fell back to the gridded
        // foundation frame ("black lines"). A slab is a single uniform tile, so render its footprint by
        // repeating the clean **built** concrete tile (group offset 2 = past the foundation/construction
        // frames). This gives a correct 2×2 (and an unchanged 1×1).
        if type == .slab1x1 || type == .slab2x2 {
            let builtConcrete = group.tileIDs.indices.contains(2) ? group.tileIDs[2] : first
            let cell = tiles.tile(builtConcrete)
            let fw = w * tw, fh = h * th
            var indices = [UInt8](repeating: 0, count: fw * fh)
            for cy in 0 ..< h {
                for cx in 0 ..< w {
                    let ox = cx * tw, oy = cy * th
                    for y in 0 ..< th {
                        for x in 0 ..< tw where y * tw + x < cell.count {
                            indices[(oy + y) * fw + ox + x] = cell[y * tw + x]
                        }
                    }
                }
            }
            return IndexedImage.cgImage(indices: indices, width: fw, height: fh, palette: assets.palette, remap: remap)
        }

        // OpenDUNE `Structure_UpdateMap` (`structure.c:1779`): the *built* tiles begin at group offset
        // `2 * layoutSize` — the first two states are the foundation / under-construction frames. So the
        // finished icon is `tileIDs[2*perState ..< 3*perState]`. This is what makes turrets show their gun,
        // walls look intact (not rubble), and concrete render clean (no placement-grid lines).
        let base = 2 * perState
        guard
            group.tileIDs.count >= base + perState
        else {
            return IndexedImage.cgImage(
                indices: tiles.tile(first),
                width: tw,
                height: th,
                palette: assets.palette,
                remap: remap
            )
        }

        let fw = w * tw, fh = h * th
        var indices = [UInt8](repeating: 0, count: fw * fh)
        for i in 0 ..< perState {
            let pixels = tiles.tile(group.tileIDs[base + i])
            guard !pixels.isEmpty else { continue }

            let originX = (i % w) * tw, originY = (i / w) * th
            for y in 0 ..< th {
                for x in 0 ..< tw {
                    let source = y * tw + x
                    if source < pixels.count { indices[(originY + y) * fw + originX + x] = pixels[source] }
                }
            }
        }
        return IndexedImage.cgImage(indices: indices, width: fw, height: fh, palette: assets.palette, remap: remap)
    }
}

/// A house-recoloured sprite for a unit/structure type, nearest-neighbour scaled to **fill** a square of
/// side `height` (wide buildings are cropped to the square rather than letterboxed).
struct SpriteThumbnail: View {
    let objectType: UInt16
    let isStructure: Bool
    let house: HouseID
    var height: CGFloat = 32
    let provider: SpriteImageProvider
    let assets: AssetStore

    var body: some View {
        if let image = provider.image(objectType: objectType, isStructure: isStructure, house: house, assets: assets) {
            Image(decorative: image, scale: 1).interpolation(.none).resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: height, height: height).clipped()
        } else {
            Image(systemName: isStructure ? "building.2.fill" : "shippingbox.fill")
                .foregroundStyle(.secondary).frame(width: height, height: height)
        }
    }
}

/// A compact command button: an SF Symbol with a small keyboard-shortcut badge, highlighted while its order
/// is armed. Used for the selection's unit orders + structure actions.
struct ActionIcon: View {
    let systemImage: String
    var badge: String? = nil
    var active = false
    var help = ""
    var disabled = false
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // A fixed square content box + a circular border shape → every command icon is an identical
            // circle, regardless of its symbol's intrinsic width.
            Image(systemName: systemImage)
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Text(badge).font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 2)
                            .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 2))
                    }
                }
        }
        .buttonStyle(.bordered).buttonBorderShape(.circle)
        .tint(active ? .accentColor : nil).disabled(disabled).help(help)
    }
}

// MARK: - Sidebar

/// The in-game sidebar: a fixed 200pt right column — radar, house + economy, the current selection (sprite,
/// HP, command icons), a build/order list for a selected factory/starport, and a bottom button row
/// (Mentat / Options / Save / Load). Replaces the old floating Inspector + Economy + Minimap tool windows.
public struct GameSidebar: View {
    @State
    var model: GameModel
    @State
    private var sprites = SpriteImageProvider()

    /// True when the host window is full-screen (macOS) or there is no window chrome (iOS): the sidebar then
    /// goes black-on-white to blend with the black map. Windowed (macOS), it uses the system window
    /// background + adaptive text so it blends with the title-bar chrome.
    let fullScreen: Bool
    @Environment(\.colorScheme)
    private var systemScheme

    public init(model: GameModel, fullScreen: Bool = false) {
        _model = State(initialValue: model)
        self.fullScreen = fullScreen
    }

    /// Black in full-screen (matches the map); the standard window background when windowed.
    private var sidebarBackground: Color {
        #if os(macOS)
            fullScreen ? .black : Color(nsColor: .windowBackgroundColor)
        #else
            .black
        #endif
    }

    /// The sidebar's stacked contents. macOS keeps a fixed header/minimap/selection with **only the build list
    /// scrolling** (and the bottom button bar pinned). iPhone wraps the **whole** stack in one ScrollView, since
    /// in landscape the sidebar can be taller than the screen — so header, minimap, selection, build, and the
    /// buttons all scroll together.
    @ViewBuilder
    private var sidebarBody: some View {
        #if os(iOS)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        MinimapView(model: model)
                        selectionSection
                            .padding(6)
                        buildSection
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        #else
            VStack(spacing: 0) {
                MinimapView(model: model)
                selectionSection
                    .padding(6)

                ScrollView {
                    buildSection
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .padding(.vertical, 6)
            }
        #endif
    }

    public var body: some View {
        let width: Double = 250
        sidebarBody
            .frame(width: width)
            .background(sidebarBackground)
            // Full-screen: force a dark scheme so labels are white on the black sidebar. Windowed: keep the
            // inherited scheme so adaptive text stays readable on the system background.
            .environment(\.colorScheme, fullScreen ? .dark : systemScheme)
    }

    // MARK: Selection

    @ViewBuilder
    private var selectionSection: some View {
        if let s = model.selection {
            VStack(alignment: .leading, spacing: 0) {
                SelectionTitle(model: model, info: s)

                HStack(alignment: .top, spacing: 6) {
                    Spacer()
                    actionIcons(s)
                }
            }
        } else {
            Text("No selection").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
        }
    }

    /// Command icons in a single row, distributed evenly across the width (each takes an equal share and
    /// centres its circle) — works for any number of buttons.
    @ViewBuilder private func actionIcons(_ s: SelectionInfo) -> some View {
        if !s.unitActions.isEmpty {
            HStack(spacing: 3) {
                ForEach(s.unitActions, id: \.self) { a in
                    ActionIcon(
                        systemImage: a.type.systemImage,
                        badge: a.type.shortcut,
                        active: a.targeted && model.pendingOrder == a.type.orderKind,
                        help: a.label
                    ) { model.issue(a) }
                }
            }
        } else {
            StructureActionBar(model: model)
        }
    }

    // MARK: Build / order

    @ViewBuilder
    private var buildSection: some View {
        FactoryBuildList(model: model, sprites: sprites)
        StarportOrderList(model: model, sprites: sprites)
    }
}

// MARK: - Options popover

/// The Options button's content: the scenario chooser, the game speed, the game toggles (fog, health bars,
/// AI fog, force-minimap, unit limit, …) — the same `DebugPanel` controls — plus a link to the macOS Settings
/// window (audio). This is the only place the scenario is chosen now (there's no window toolbar).
struct OptionsPopover: View {
    @State
    var model: GameModel
    @Binding
    var isPresented: Bool
    #if os(macOS)
        // macOS presents the scenario picker as a nested popover off this row; iOS pushes it onto the Options
        // NavigationStack via a NavigationLink, so it needs no presentation flag.
        @State
        private var showScenario = false
    #endif

    init(model: GameModel, isPresented: Binding<Bool>) {
        _model = State(initialValue: model)
        _isPresented = isPresented
    }

    var body: some View {
        #if os(iOS)
            // Full-screen on the phone, wrapped in a NavigationStack for a title bar + a Done button to dismiss
            // (a `fullScreenCover` has no built-in dismiss). The content's own Forms scroll.
            NavigationStack {
                content
                    .navigationTitle("Options")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isPresented = false }
                        }
                    }
            }
        #else
            content.gamePopover(width: 380, maxHeight: 540)
        #endif
    }

    /// The "Scenario" row. iOS pushes the picker full-screen (a single tappable row); macOS pops it as a
    /// nested popover off a labelled button.
    @ViewBuilder
    private var scenarioRow: some View {
        #if os(iOS)
            NavigationLink {
                ScenarioPicker(model: model)
            } label: {
                LabeledContent("Scenario", value: model.scenarioTitle)
            }
            .disabled(model.assets.scenarioNames.isEmpty)
        #else
            LabeledContent("Scenario") {
                Button {
                    showScenario = true
                } label: {
                    Label(model.scenarioTitle, systemImage: "map")
                }
                .disabled(model.assets.scenarioNames.isEmpty)
                .popover(isPresented: $showScenario, arrowEdge: .leading) {
                    ScenarioPicker(model: model)
                }
            }
        #endif
    }

    private var content: some View {
        // One Form — a single scroll region. The scenario/speed controls and the debug toggles used to be two
        // stacked Forms (each its own scroller); now they're sections of the same Form.
        Form {
            Section {
                scenarioRow
                Picker("Game speed", selection: Binding(get: { model.gameSpeed }, set: { model.gameSpeed = $0 })) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }
                .pickerStyle(.segmented)
                LabeledContent("Zoom") {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(get: { model.viewport.zoom }, set: { model.setZoom($0) }),
                            in: Viewport.minZoom ... Viewport.maxZoom
                        )
                        Text("\(model.viewport.zoom, specifier: "%.1f")×")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("Audio") { AudioSettingsRows(model: model) }
            Section { DebugToggleRows(model: model) }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Build requirements popover

/// What a locked build item still needs, shown when the player taps its greyed row: one line per blocker
/// (a missing prerequisite structure, or a required factory upgrade). Campaign-gated items are hidden from
/// the list entirely, so they never reach this popover.
struct RequirementsPopover: View {
    let name: String
    let blockers: [BuildBlocker]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(name).font(.headline)
                Text(blockers.isEmpty ? "Available to build." : "Needs:").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(blockers.enumerated()), id: \.offset) { _, blocker in
                    Label(blocker.summary, systemImage: icon(for: blocker)).font(.callout)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .gamePopover(width: 240, maxHeight: 320)
    }

    private func icon(for blocker: BuildBlocker) -> String {
        switch blocker {
            case .campaign: "calendar"
            case .structure: "building.2.fill"
            case .upgradeLevel: "arrow.up.circle"
        }
    }
}
