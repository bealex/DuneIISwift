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

    private struct DecodedFrame { let pixels: [UInt8]; let w: Int; let h: Int; let hasLookup: Bool }

    private static func unitFrame(_ globalIndex: Int, assets: AssetStore) -> DecodedFrame? {
        guard let (sheet, frame) = GlobalSprite.unit(globalIndex), let set = assets.shp(sheet.fileName),
              frame >= 0, frame < set.frames.count else { return nil }
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
        guard info.turretSpriteID != 0xFFFF, let turret = unitFrame(Int(info.turretSpriteID), assets: assets) else {
            return IndexedImage.cgImage(indices: body.pixels, width: body.w, height: body.h, palette: assets.palette,
                                        transparentIndex: 0, remap: { resolve($0, body.hasLookup) })
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
                    if idx == 0 { continue }   // transparent
                    canvas[(oy + y) * cw + (ox + x)] = resolve(idx, f.hasLookup)
                }
            }
        }
        blit(body, atX: bx0 - minX, atY: by0 - minY)
        blit(turret, atX: tx0 - minX, atY: ty0 - minY)   // gun on top
        return IndexedImage.cgImage(indices: canvas, width: cw, height: ch, palette: assets.palette,
                                    transparentIndex: 0, remap: { $0 })   // already house-resolved
    }

    /// Orientation-0 turret pixel offset — the north-facing slice of `UnitSprites.turretOffset` (`viewport.c`).
    private static func turretOffset0(_ turretSpriteID: UInt16) -> (Int, Int) {
        switch turretSpriteID {
            case 141: return (0, -2)   // sonic tank
            case 146: return (0, -3)   // launcher / deviator
            case 126: return (0, -5)   // siege tank
            case 136: return (0, -4)   // devastator
            default:  return (0, 0)    // combat tank, …
        }
    }

    private static func structureImage(_ objectType: UInt16, house: HouseID, assets: AssetStore) -> CGImage? {
        guard let type = StructureType(rawValue: Int(objectType)),
              let tiles = assets.tileSet, let iconMap = assets.iconMap else { return nil }
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

        // OpenDUNE `Structure_UpdateMap` (`structure.c:1779`): the *built* tiles begin at group offset
        // `2 * layoutSize` — the first two states are the foundation / under-construction frames. So the
        // finished icon is `tileIDs[2*perState ..< 3*perState]`. This is what makes turrets show their gun,
        // walls look intact (not rubble), and concrete render clean (no placement-grid lines).
        let base = 2 * perState
        guard group.tileIDs.count >= base + perState else {
            return IndexedImage.cgImage(indices: tiles.tile(first), width: tw, height: th,
                                        palette: assets.palette, remap: remap)
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
    @State var model: GameModel
    /// Save/Load are platform-specific (macOS `NSSavePanel` ↔ iOS `UIDocumentPicker`), so the app shell
    /// injects them. Everything else is shared.
    let onSave: () -> Void
    let onLoad: () -> Void
    @State private var sprites = SpriteImageProvider()
    @State private var showOptions = false
    @State private var showMentat = false

    /// True when the host window is full-screen (macOS) or there is no window chrome (iOS): the sidebar then
    /// goes black-on-white to blend with the black map. Windowed (macOS), it uses the system window
    /// background + adaptive text so it blends with the title-bar chrome.
    let fullScreen: Bool
    @Environment(\.colorScheme) private var systemScheme


    public init(model: GameModel, fullScreen: Bool = false,
                onSave: @escaping () -> Void, onLoad: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.fullScreen = fullScreen
        self.onSave = onSave
        self.onLoad = onLoad
    }

    /// Black in full-screen (matches the map); the standard window background when windowed.
    private var sidebarBackground: Color {
        #if os(macOS)
        fullScreen ? .black : Color(nsColor: .windowBackgroundColor)
        #else
        .black
        #endif
    }

    public var body: some View {
        VStack(spacing: 0) {
            MinimapView(model: model).frame(height: 184)
            Divider()
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    selectionSection
                    buildSection
                    Spacer(minLength: 0)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            bottomBar
        }
        .frame(width: 200)
        .background(sidebarBackground)
        // Full-screen: force a dark scheme so labels are white on the black sidebar. Windowed: keep the
        // inherited scheme so adaptive text stays readable on the system background.
        .environment(\.colorScheme, fullScreen ? .dark : systemScheme)
        .sheet(isPresented: $showMentat) {
            if let s = model.selection { MentatSheet(info: s, provider: sprites, assets: model.assets) }
        }
    }

    // MARK: House + economy

    private var header: some View {
        let e = model.economy.first { $0.isPlayer }
        let mission = model.currentScenario.flatMap { ScenarioID(fileName: $0)?.mission }
        let powerOK = e.map { $0.power >= $0.powerUsed } ?? true
        return VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.playerHouse.displayName).font(.title3.bold())
                if let mission {
                    Text("Mission \(mission)").font(.caption).foregroundStyle(.secondary)
                }
            }
            // Credits and power each take half the width, centred within their half.
            HStack(spacing: 8) {
                Label("\(model.playerCredits)", systemImage: "dollarsign.circle.fill")
                    .monospacedDigit().foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity)
                Label("\(e?.power ?? 0)/\(e?.powerUsed ?? 0)", systemImage: "bolt.fill")
                    .monospacedDigit().foregroundStyle(powerOK ? Color.secondary : Color.red)
                    .help("Power produced / consumed")
                    .frame(maxWidth: .infinity)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
    }

    // MARK: Selection

    @ViewBuilder private var selectionSection: some View {
        if let s = model.selection {
            HStack(alignment: .top, spacing: 8) {
                SpriteThumbnail(objectType: s.typeRaw, isStructure: s.kind == .structure, house: s.houseID,
                                height: 44, provider: sprites, assets: model.assets)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(s.name).font(.headline).lineLimit(2).lineHeight(.tight)
                        if model.selectedUnitCount > 1 {
                            Text("×\(model.selectedUnitCount)").font(.caption.bold())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.25), in: Capsule())
                        }
                    }
                    Text(s.isPlayer ? s.state : s.house).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("HP").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(s.hitpoints) / \(s.hitpointsMax)").font(.caption.monospacedDigit())
                }
                ProgressView(value: Double(s.hitpoints), total: Double(max(s.hitpointsMax, 1)))
                    .tint(hpTint(s.hitpoints, s.hitpointsMax))
            }
            actionIcons(s)
        } else {
            Text("No selection").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
        }
    }

    /// Command icons in a single row, distributed evenly across the width (each takes an equal share and
    /// centres its circle) — works for any number of buttons.
    @ViewBuilder private func actionIcons(_ s: SelectionInfo) -> some View {
        if !s.unitActions.isEmpty {
            HStack(spacing: 0) {
                ForEach(s.unitActions, id: \.self) { a in
                    ActionIcon(systemImage: a.type.systemImage, badge: a.type.shortcut,
                               active: a.targeted && model.pendingOrder == a.type.orderKind,
                               help: a.label) { model.issue(a) }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        if model.structureActions != nil || model.superWeapon != nil {
            HStack(spacing: 0) {
                if let sa = model.structureActions {
                    ActionIcon(systemImage: "wrench.and.screwdriver", badge: "R", active: sa.isRepairing,
                               help: sa.isRepairing ? "Stop repairing (R)" : "Repair (R)",
                               disabled: !sa.canRepair && !sa.isRepairing) { model.repairSelected() }
                        .frame(maxWidth: .infinity)
                    ActionIcon(systemImage: "arrow.up.circle", badge: "U", active: sa.isUpgrading,
                               help: sa.isUpgrading ? "Stop upgrading (U)" : "Upgrade (U)",
                               disabled: !sa.canUpgrade && !sa.isUpgrading) { model.upgradeSelected() }
                        .frame(maxWidth: .infinity)
                }
                if let sw = model.superWeapon {
                    ActionIcon(systemImage: sw.systemImage, active: model.missileTargeting != nil,
                               help: sw.ready ? sw.title : "Recharging…", disabled: !sw.ready) { model.launchSuperWeapon() }
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Build / order

    @ViewBuilder private var buildSection: some View {
        if model.isFactorySelected {
            Divider()
            if let bs = model.buildProgress {
                buildProgress(bs)
            } else if model.buildOptions.isEmpty {
                Text("Nothing available to build.").font(.caption).foregroundStyle(.secondary)
            } else {
                // Every item this factory could build; locked ones greyed-out with a "what's missing" tooltip.
                VStack(spacing: 4) {
                    ForEach(model.buildOptions, id: \.item.objectType) { option in
                        let item = option.item
                        let underfunded = option.isAvailable && item.cost > model.playerCredits
                        Button { model.startBuild(item.objectType) } label: {
                            optionRow(objectType: item.objectType, isStructure: item.isStructure,
                                      name: item.displayName, cost: item.cost, locked: !option.isAvailable,
                                      underfunded: underfunded)
                        }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        .disabled(!option.isAvailable).help(buildHelp(option))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if !model.starportStock.isEmpty {
            Divider()
            Text("Order (Starport)").font(.headline)
            VStack(spacing: 4) {
                ForEach(model.starportStock, id: \.objectType) { item in
                    Button { model.orderFromStarport(item.objectType) } label: {
                        optionRow(objectType: item.objectType, isStructure: item.isStructure,
                                  name: item.displayName, cost: item.cost, locked: false,
                                  underfunded: item.cost > model.playerCredits)
                    }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    .disabled(item.cost > model.playerCredits)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func optionRow(objectType: UInt16, isStructure: Bool, name: String, cost: Int,
                           locked: Bool, underfunded: Bool) -> some View {
        HStack(spacing: 6) {
            SpriteThumbnail(objectType: objectType, isStructure: isStructure, house: model.playerHouse,
                            height: 22, provider: sprites, assets: model.assets)
                .frame(width: 30, alignment: .center)
            // The title absorbs the slack (maxWidth .infinity) so the lock + cost pin to the trailing edge —
            // every row is aligned on both the left (title) and right (cost) sides.
            Text(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if locked { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
            Text("\(cost)").font(.caption.monospacedDigit()).foregroundStyle(underfunded ? Color.red : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func buildProgress(_ bs: BuildState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Big icon (2× the list thumbnails) + the product name; no status text.
            HStack(spacing: 10) {
                SpriteThumbnail(objectType: bs.objectType, isStructure: bs.isStructure, house: model.playerHouse,
                                height: 44, provider: sprites, assets: model.assets)
                Text(bs.displayName).font(.headline).lineLimit(2).lineHeight(.tight)
                Spacer(minLength: 0)
            }
            ProgressView(value: bs.progress).tint(bs.onHold ? .orange : .accentColor)
            // Bigger circular buttons — only the action that applies right now (place / resume / pause) + stop.
            HStack(spacing: 12) {
                if bs.isReady && bs.isStructure {
                    ActionIcon(systemImage: "mappin.and.ellipse", active: true, help: "Place", size: 40) { model.beginPlacement() }
                } else if bs.onHold {
                    ActionIcon(systemImage: "play.fill", active: true, help: "Resume", size: 40) { model.resumeBuild() }
                } else if !bs.isReady {
                    ActionIcon(systemImage: "pause.fill", help: "Pause", size: 40) { model.pauseBuild() }
                }
                ActionIcon(systemImage: "xmark", help: "Stop", size: 40) { model.cancelBuild() }
            }
            if model.placement != nil {
                Text("Click a spot to place · Esc / right-click cancels")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Bottom button row

    private var bottomBar: some View {
        // Four equal circular buttons, spread evenly across the column width.
        HStack(spacing: 0) {
            sidebarButton("brain.head.profile", help: "Mentat — info on the selected unit/building",
                          disabled: model.selection == nil) { showMentat = true }
            Spacer()
            sidebarButton("gearshape.fill", help: "Options") { showOptions = true }
                .popover(isPresented: $showOptions, arrowEdge: .top) { OptionsPopover(model: model) }
            Spacer()
            sidebarButton("square.and.arrow.down", help: "Save game…") { onSave() }
            Spacer()
            sidebarButton("folder", help: "Load game…") { onLoad() }
        }
        .frame(maxWidth: .infinity)
        .padding(6)
    }

    private func sidebarButton(_ systemImage: String, help: String, disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered).buttonBorderShape(.circle).disabled(disabled).help(help)
    }

    private func hpTint(_ hp: Int, _ maxHP: Int) -> Color {
        let f = maxHP > 0 ? Double(hp) / Double(maxHP) : 1
        return f > 0.66 ? .green : (f > 0.33 ? .yellow : .red)
    }

    private func buildHelp(_ option: BuildOption) -> String {
        let item = option.item
        if !option.isAvailable { return "Requires: " + option.blockers.map(\.summary).joined(separator: ", ") }
        if item.cost > model.playerCredits {
            return "Costs \(item.cost) cr — you have \(model.playerCredits); construction starts and pauses until you can pay."
        }
        return "Build \(item.displayName) (\(item.cost) cr)"
    }
}

// MARK: - Options popover

/// The Options button's content: the game toggles (fog, health bars, AI fog, force-minimap, unit limit, …)
/// — the same `DebugPanel` controls — plus a link to the macOS Settings window (audio).
struct OptionsPopover: View {
    @State var model: GameModel

    var body: some View {
        VStack(spacing: 0) {
            DebugPanel(model: model)
            Divider()
            HStack {
                SettingsLink { Label("Settings…", systemImage: "slider.horizontal.3") }
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 310, height: 440)
    }
}

// MARK: - Mentat info sheet

/// A lightweight "Mentat" info sheet for the selected unit/building: its sprite + key stats. (A stand-in for
/// the original animated Mentat advisor screen.)
struct MentatSheet: View {
    let info: SelectionInfo
    let provider: SpriteImageProvider
    let assets: AssetStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(info.name).font(.title.bold())
            SpriteThumbnail(objectType: info.typeRaw, isStructure: info.kind == .structure, house: info.houseID,
                            height: 96, provider: provider, assets: assets)
                .frame(height: 100)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(stats, id: \.0) { row in
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary)
                        Text(row.1).monospacedDigit()
                    }
                }
            }
            .font(.callout)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24).frame(width: 320)
    }

    /// Key stats for the selected type, pulled from the stat tables.
    private var stats: [(String, String)] {
        var rows: [(String, String)] = [("House", info.house), ("Health", "\(info.hitpoints) / \(info.hitpointsMax)")]
        if info.kind == .unit, let type = UnitType(rawValue: Int(info.typeRaw)) {
            let u = UnitInfo[type]
            if u.damage > 0 { rows.append(("Damage", "\(u.damage)")) }
            if u.fireDistance > 0 { rows.append(("Range", "\(u.fireDistance)")) }
        } else if info.kind == .structure, let type = StructureType(rawValue: Int(info.typeRaw)) {
            let s = StructureInfo[type]
            let power = Int(s.powerUsage)   // positive = consumed, negative = produced
            if power != 0 { rows.append((power < 0 ? "Power produced" : "Power used", "\(abs(power))")) }
            if s.creditsStorage > 0 { rows.append(("Spice storage", "\(s.creditsStorage)")) }
        }
        return rows
    }
}
