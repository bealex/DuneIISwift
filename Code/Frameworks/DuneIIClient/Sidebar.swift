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

    private static func unitImage(_ objectType: UInt16, house: HouseID, assets: AssetStore) -> CGImage? {
        guard let type = UnitType(rawValue: Int(objectType)) else { return nil }
        let gid = Int(UnitInfo[type].groundSpriteID)
        guard let (sheet, frame) = GlobalSprite.unit(gid), let set = assets.shp(sheet.fileName),
              frame >= 0, frame < set.frames.count else { return nil }
        let f = set.frames[frame]
        // Only frames carrying a house-colour lookup get the sprite remap (matches `rendertest`).
        let remapHouse = DuneIIRenderer.House(rawValue: house.rawValue) ?? .harkonnen
        let remap: (UInt8) -> UInt8 = f.hasLookup ? { HouseRemap.sprite($0, house: remapHouse) } : { $0 }
        return IndexedImage.cgImage(indices: f.pixels, width: f.width, height: f.height,
                                    palette: assets.palette, transparentIndex: 0, remap: remap)
    }

    private static func structureImage(_ objectType: UInt16, house: HouseID, assets: AssetStore) -> CGImage? {
        guard let type = StructureType(rawValue: Int(objectType)),
              let tiles = assets.tileSet, let iconMap = assets.iconMap else { return nil }
        let groupIndex = Int(StructureInfo[type].iconGroup)
        guard let group = iconMap.group(groupIndex), let first = group.tileIDs.first else { return nil }
        let remapHouse = DuneIIRenderer.House(rawValue: house.rawValue) ?? .harkonnen
        let remap: (UInt8) -> UInt8 = { HouseRemap.tile($0, house: remapHouse) }
        let tw = tiles.tileWidth, th = tiles.tileHeight

        // A multi-tile building: stitch the `width*height` tiles of the completed build state (index 2, per
        // `Structure_UpdateMap`, `structure.c:1779`) into one image, row-major. 1×1 turrets fall through.
        if let layout = StructureCatalog.layout(iconGroup: groupIndex), layout.width * layout.height > 1,
           group.tileIDs.count % (layout.width * layout.height) == 0 {
            let perState = layout.width * layout.height
            let state = min(2, group.tileIDs.count / perState - 1)
            let fw = layout.width * tw, fh = layout.height * th
            var indices = [UInt8](repeating: 0, count: fw * fh)
            for i in 0 ..< perState {
                let pixels = tiles.tile(group.tileIDs[state * perState + i])
                guard !pixels.isEmpty else { continue }
                let originX = (i % layout.width) * tw, originY = (i / layout.width) * th
                for y in 0 ..< th {
                    for x in 0 ..< tw {
                        let source = y * tw + x
                        if source < pixels.count { indices[(originY + y) * fw + originX + x] = pixels[source] }
                    }
                }
            }
            return IndexedImage.cgImage(indices: indices, width: fw, height: fh, palette: assets.palette, remap: remap)
        }
        return IndexedImage.cgImage(indices: tiles.tile(first), width: tw, height: th, palette: assets.palette, remap: remap)
    }
}

/// A house-recoloured sprite for a unit/structure type, nearest-neighbour scaled to fit `height`.
struct SpriteThumbnail: View {
    let objectType: UInt16
    let isStructure: Bool
    let house: HouseID
    var height: CGFloat = 32
    let provider: SpriteImageProvider
    let assets: AssetStore

    var body: some View {
        if let image = provider.image(objectType: objectType, isStructure: isStructure, house: house, assets: assets) {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit().frame(height: height)
        } else {
            Image(systemName: isStructure ? "building.2.fill" : "shippingbox.fill")
                .foregroundStyle(.secondary).frame(height: height)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 38, height: 28)
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Text(badge).font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 2)
                            .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 2))
                            .padding(1)
                    }
                }
        }
        .buttonStyle(.bordered).tint(active ? .accentColor : nil).disabled(disabled).help(help)
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

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 6, alignment: .leading)]

    public init(model: GameModel, onSave: @escaping () -> Void, onLoad: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onSave = onSave
        self.onLoad = onLoad
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
        .background(Color(white: 0.10))
        .sheet(isPresented: $showMentat) {
            if let s = model.selection { MentatSheet(info: s, provider: sprites, assets: model.assets) }
        }
    }

    // MARK: House + economy

    private var header: some View {
        let e = model.economy.first { $0.isPlayer }
        return VStack(alignment: .leading, spacing: 4) {
            Text(model.playerHouse.displayName).font(.title3.bold())
            HStack(spacing: 12) {
                Label("\(model.playerCredits)", systemImage: "dollarsign.circle.fill")
                    .monospacedDigit().foregroundStyle(.yellow)
                if let e {
                    Label("\(e.power)/\(e.powerUsed)", systemImage: "bolt.fill")
                        .monospacedDigit().foregroundStyle(e.power >= e.powerUsed ? Color.secondary : Color.red)
                        .help("Power produced / consumed")
                }
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
                                height: 40, provider: sprites, assets: model.assets)
                    .frame(width: 48, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(s.name).font(.headline).lineLimit(1)
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

    @ViewBuilder private func actionIcons(_ s: SelectionInfo) -> some View {
        if !s.unitActions.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(s.unitActions, id: \.self) { a in
                    ActionIcon(systemImage: a.type.systemImage, badge: a.type.shortcut,
                               active: a.targeted && model.pendingOrder == a.type.orderKind,
                               help: a.label) { model.issue(a) }
                }
            }
        }
        if model.structureActions != nil || model.superWeapon != nil {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                if let sa = model.structureActions {
                    ActionIcon(systemImage: "wrench.and.screwdriver", badge: "R", active: sa.isRepairing,
                               help: sa.isRepairing ? "Stop repairing (R)" : "Repair (R)",
                               disabled: !sa.canRepair && !sa.isRepairing) { model.repairSelected() }
                    ActionIcon(systemImage: "arrow.up.circle", badge: "U", active: sa.isUpgrading,
                               help: sa.isUpgrading ? "Stop upgrading (U)" : "Upgrade (U)",
                               disabled: !sa.canUpgrade && !sa.isUpgrading) { model.upgradeSelected() }
                }
                if let sw = model.superWeapon {
                    ActionIcon(systemImage: sw.systemImage, active: model.missileTargeting != nil,
                               help: sw.ready ? sw.title : "Recharging…", disabled: !sw.ready) { model.launchSuperWeapon() }
                }
            }
        }
    }

    // MARK: Build / order

    @ViewBuilder private var buildSection: some View {
        if model.isFactorySelected {
            Divider()
            Text("Build").font(.headline)
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
                        .buttonStyle(.bordered).disabled(!option.isAvailable).help(buildHelp(option))
                    }
                }
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
                    .buttonStyle(.bordered).disabled(item.cost > model.playerCredits)
                }
            }
        }
    }

    private func optionRow(objectType: UInt16, isStructure: Bool, name: String, cost: Int,
                           locked: Bool, underfunded: Bool) -> some View {
        HStack(spacing: 6) {
            SpriteThumbnail(objectType: objectType, isStructure: isStructure, house: model.playerHouse,
                            height: 22, provider: sprites, assets: model.assets)
                .frame(width: 30, alignment: .center)
            Text(name).lineLimit(1)
            if locked { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 4)
            Text("\(cost)").font(.caption.monospacedDigit()).foregroundStyle(underfunded ? Color.red : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func buildProgress(_ bs: BuildState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SpriteThumbnail(objectType: bs.objectType, isStructure: bs.isStructure, house: model.playerHouse,
                                height: 22, provider: sprites, assets: model.assets)
                    .frame(width: 30, alignment: .center)
                Text(bs.displayName).font(.callout.bold()).lineLimit(1)
                Spacer(minLength: 0)
                if bs.isReady { Text("Ready").font(.caption).foregroundStyle(.green) }
                else if bs.onHold { Text("Hold").font(.caption).foregroundStyle(.orange) }
            }
            ProgressView(value: bs.progress).tint(bs.onHold ? .orange : .accentColor)
            HStack(spacing: 6) {
                if bs.isReady && bs.isStructure {
                    Button { model.beginPlacement() } label: { Label("Place", systemImage: "mappin.and.ellipse") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                } else if bs.isReady {
                    Label("Deploying…", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.green)
                } else if bs.onHold {
                    Button { model.resumeBuild() } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button { model.pauseBuild() } label: { Image(systemName: "pause.fill") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button(role: .destructive) { model.cancelBuild() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if model.placement != nil {
                Text("Click a spot to place · Esc / right-click cancels")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Bottom button row

    private var bottomBar: some View {
        HStack(spacing: 4) {
            sidebarButton("brain.head.profile", help: "Mentat — info on the selected unit/building",
                          disabled: model.selection == nil) { showMentat = true }
            sidebarButton("gearshape.fill", help: "Options") { showOptions = true }
                .popover(isPresented: $showOptions, arrowEdge: .top) { OptionsPopover(model: model) }
            sidebarButton("square.and.arrow.down", help: "Save game…") { onSave() }
            sidebarButton("folder", help: "Load game…") { onLoad() }
        }
        .padding(6)
    }

    private func sidebarButton(_ systemImage: String, help: String, disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(maxWidth: .infinity, minHeight: 26)
        }
        .buttonStyle(.bordered).disabled(disabled).help(help)
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
