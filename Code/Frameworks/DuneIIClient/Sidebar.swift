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
        var canvas = [ UInt8 ](repeating: 0, count: cw * ch)
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
        switch turretSpriteID {
            case 141: return (0, -2)  // sonic tank
            case 146: return (0, -3)  // launcher / deviator
            case 126: return (0, -5)  // siege tank
            case 136: return (0, -4)  // devastator
            default: return (0, 0)  // combat tank, …
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
        var indices = [ UInt8 ](repeating: 0, count: fw * fh)
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
    /// The locked build row whose "what's needed" popover is open (by object type), or nil.
    @State private var requirementsFor: UInt16?

    /// True when the host window is full-screen (macOS) or there is no window chrome (iOS): the sidebar then
    /// goes black-on-white to blend with the black map. Windowed (macOS), it uses the system window
    /// background + adaptive text so it blends with the title-bar chrome.
    let fullScreen: Bool
    @Environment(\.colorScheme) private var systemScheme

    public init(
        model: GameModel,
        fullScreen: Bool = false,
        onSave: @escaping () -> Void,
        onLoad: @escaping () -> Void
    ) {
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
        let width: Double = 250
        VStack(spacing: 0) {
            header
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

            Divider()
            bottomBar
        }
        .frame(width: width)
        .background(sidebarBackground)
        // Full-screen: force a dark scheme so labels are white on the black sidebar. Windowed: keep the
        // inherited scheme so adaptive text stays readable on the system background.
        .environment(\.colorScheme, fullScreen ? .dark : systemScheme)
        .popover(isPresented: $showMentat, arrowEdge: .leading) {
            MentatView(model: model, provider: sprites)
        }
        // Freeze the game while the options popover or the mentat help is open, then resume to the player's
        // own pause state (balanced begin/end so opening one while the other is up still resumes correctly).
        .onChange(of: showOptions) { _, open in open ? model.beginUIPause() : model.endUIPause() }
        .onChange(of: showMentat) { _, open in open ? model.beginUIPause() : model.endUIPause() }
    }

    // MARK: House + economy

    private var header: some View {
        let e = model.economy.first { $0.isPlayer }
        let mission = model.currentScenario.flatMap { ScenarioID(fileName: $0)?.mission }
        let powerOK = e.map { $0.power >= $0.powerUsed } ?? true
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
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
            .font(.body.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
    }

    // MARK: Selection

    @ViewBuilder private var selectionSection: some View {
        if let s = model.selection {
            HStack(alignment: .top, spacing: 12) {
                SpriteThumbnail(
                    objectType: s.typeRaw,
                    isStructure: s.kind == .structure,
                    house: s.houseID,
                    height: 44,
                    provider: sprites,
                    assets: model.assets
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))

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
                    Text("\(s.hitpoints) / \(s.hitpointsMax)").font(.caption.monospacedDigit()).frame(
                        maxWidth: .infinity
                    )
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
                    ActionIcon(
                        systemImage: a.type.systemImage,
                        badge: a.type.shortcut,
                        active: a.targeted && model.pendingOrder == a.type.orderKind,
                        help: a.label
                    ) { model.issue(a) }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        if model.structureActions != nil || model.superWeapon != nil {
            HStack(spacing: 0) {
                if let sa = model.structureActions {
                    ActionIcon(
                        systemImage: "wrench.and.screwdriver",
                        badge: "R",
                        active: sa.isRepairing,
                        help: sa.isRepairing ? "Stop repairing (R)" : "Repair (R)",
                        disabled: !sa.canRepair && !sa.isRepairing
                    ) { model.repairSelected() }
                    .frame(maxWidth: .infinity)
                    ActionIcon(
                        systemImage: "arrow.up.circle",
                        badge: "U",
                        active: sa.isUpgrading,
                        help: sa.isUpgrading ? "Stop upgrading (U)" : "Upgrade (U)",
                        disabled: !sa.canUpgrade && !sa.isUpgrading
                    ) { model.upgradeSelected() }
                    .frame(maxWidth: .infinity)
                }
                if let sw = model.superWeapon {
                    ActionIcon(
                        systemImage: sw.systemImage,
                        active: model.missileTargeting != nil,
                        help: sw.ready ? sw.title : "Recharging…",
                        disabled: !sw.ready
                    ) { model.launchSuperWeapon() }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Build / order

    @ViewBuilder private var buildSection: some View {
        if model.isFactorySelected {
            if let bs = model.buildProgress {
                buildProgress(bs)
            } else if model.buildOptions.isEmpty {
                Text("Nothing available to build.").font(.caption).foregroundStyle(.secondary)
            } else {
                // Every item this factory could build; locked ones stay greyed but clickable — a tap opens a
                // "what's needed" popover (the hover tooltip says the same for mouse users).
                VStack(spacing: 3) {
                    ForEach(model.buildOptions, id: \.item.objectType) { option in
                        let item = option.item
                        let underfunded = option.isAvailable && item.cost > model.playerCredits

                        Button {
                            if option.isAvailable {
                                model.startBuild(item.objectType)
                            } else {
                                requirementsFor = item.objectType
                            }
                        } label: {
                            optionRow(
                                objectType: item.objectType,
                                isStructure: item.isStructure,
                                name: item.displayName,
                                cost: item.cost,
                                locked: !option.isAvailable,
                                underfunded: underfunded
                            )
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Color.gray.opacity(option.isAvailable ? 0.2 : 0),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                        .help(buildHelp(option))
                        .popover(
                            isPresented: Binding(
                                get: { requirementsFor == item.objectType },
                                set: { if !$0 { requirementsFor = nil } }
                            ),
                            arrowEdge: .leading
                        ) {
                            RequirementsPopover(name: item.displayName, blockers: option.blockers)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if model.isStarportSelected {
            Divider()
            Text("Order (Starport)").font(.headline)
            // A pending delivery: the frigate-arrival countdown (the original shows this only as the frigate
            // flying in; we add a progress bar so the wait is legible).
            if let d = model.starportDelivery {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Frigate inbound…", systemImage: "airplane.arrival")
                        .font(.caption2).foregroundStyle(.secondary)
                    ProgressView(value: d.fraction).tint(.yellow)
                }
            }
            if model.starportStock.isEmpty {
                Text("No CHOAM stock.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 3) {
                    ForEach(model.starportStock, id: \.objectType) { item in starportRow(item) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The staged order: total + Order / Cancel (charged only on Order).
                if model.cartUnitCount > 0 {
                    HStack(spacing: 4) {
                        Text("\(model.cartUnitCount)×").font(.caption.bold().monospacedDigit())
                        Spacer(minLength: 0)
                        Text("\(model.cartTotalCost) cr").font(.caption.monospacedDigit())
                            .foregroundStyle(model.cartTotalCost > model.playerCredits ? Color.red : .secondary)
                    }
                    .padding(.top, 2)
                    HStack(spacing: 6) {
                        Button {
                            model.sendStarportOrder()
                        } label: {
                            Label("Order", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.cartTotalCost > model.playerCredits)
                        Button(role: .destructive) {
                            model.clearStarportCart()
                        } label: {
                            Label("Clear", systemImage: "xmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    /// One CHOAM order line: the unit thumbnail + name, its stock and price, and a −/＋ stepper that stages
    /// the unit in the order cart. Greyed when sold out; the ＋ disables at the stock limit or when the running
    /// cart total would exceed the player's credits.
    @ViewBuilder private func starportRow(_ item: StarportItem) -> some View {
        let count = model.cartCount(item.objectType)
        HStack(spacing: 6) {
            SpriteThumbnail(
                objectType: item.objectType,
                isStructure: false,
                house: model.playerHouse,
                height: 24,
                provider: sprites,
                assets: model.assets
            )
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .opacity(item.soldOut ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.displayName).font(.caption).lineLimit(1)
                    .foregroundStyle(item.soldOut ? .secondary : .primary)
                HStack(spacing: 3) {
                    Text(item.soldOut ? "Sold out" : "\(item.available) left")
                        .foregroundStyle(item.soldOut ? Color.red : .secondary)
                    if !item.soldOut {
                        Text("· \(item.cost)")
                            .foregroundStyle(item.cost > model.playerCredits ? Color.red : .secondary)
                    }
                }
                .font(.system(size: 9)).monospacedDigit()
            }
            Spacer(minLength: 0)
            if count > 0 {
                stepButton("minus") { model.cartRemove(item.objectType) }
                Text("\(count)").font(.caption.monospacedDigit().bold()).frame(minWidth: 12)
            }
            stepButton("plus", disabled: !model.canAddToCart(item)) { model.cartAdd(item.objectType) }
        }
    }

    private func stepButton(
        _ systemImage: String,
        disabled: Bool = false,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered).buttonBorderShape(.circle).disabled(disabled)
    }

    private func optionRow(
        objectType: UInt16,
        isStructure: Bool,
        name: String,
        cost: Int,
        locked: Bool,
        underfunded: Bool
    ) -> some View {
        HStack(spacing: 6) {
            // A fixed, leading-pinned square so every row's thumbnail occupies identical space and the title
            // starts at the same x — the icon is left-aligned to the row, never centred in a wider column.
            SpriteThumbnail(
                objectType: objectType,
                isStructure: isStructure,
                house: model.playerHouse,
                height: 39,
                provider: sprites,
                assets: model.assets
            )
            .frame(width: 39, height: 39)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .opacity(locked ? 0.45 : 1)

            // The title absorbs the slack (maxWidth .infinity) so the lock + cost pin to the trailing edge —
            // every row is aligned on both the left (title) and right (cost) sides. Locked rows are greyed
            // (we no longer `.disabled` them, so they stay tappable for the requirements popover).
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(name)
                        .font(.title3)
                        .lineLimit(1)
                        .foregroundStyle(locked ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if locked {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Text("\(cost)").font(.caption.monospacedDigit()).foregroundStyle(
                    underfunded ? Color.red : Color.secondary
                )
            }
        }
    }

    @ViewBuilder private func buildProgress(_ bs: BuildState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Big icon (2× the list thumbnails) + the product name, pinned top-trailing; no status text.
            HStack(alignment: .top, spacing: 10) {
                SpriteThumbnail(
                    objectType: bs.objectType,
                    isStructure: bs.isStructure,
                    house: model.playerHouse,
                    height: 44,
                    provider: sprites,
                    assets: model.assets
                )
                Spacer(minLength: 0)
                Text(bs.displayName).font(.headline).lineLimit(2).lineHeight(.tight)
                    .multilineTextAlignment(.trailing)
            }
            ProgressView(value: bs.progress).tint(bs.onHold ? .orange : .accentColor)
            // Only the action that applies right now (place / resume / pause) + stop, evenly distributed.
            HStack(spacing: 0) {
                if bs.isReady && bs.isStructure {
                    ActionIcon(systemImage: "mappin.and.ellipse", active: true, help: "Place") {
                        model.beginPlacement()
                    }
                    .frame(maxWidth: .infinity)
                } else if bs.onHold {
                    ActionIcon(systemImage: "play.fill", active: true, help: "Resume") { model.resumeBuild() }
                        .frame(maxWidth: .infinity)
                } else if !bs.isReady {
                    ActionIcon(systemImage: "pause.fill", help: "Pause") { model.pauseBuild() }
                        .frame(maxWidth: .infinity)
                }
                ActionIcon(systemImage: "xmark", help: "Stop") { model.cancelBuild() }
                    .frame(maxWidth: .infinity)
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
            sidebarButton("brain.head.profile", help: "Mentat — buildings, units, and house info") { showMentat = true }
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

    private func sidebarButton(
        _ systemImage: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
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
            return
                "Costs \(item.cost) cr — you have \(model.playerCredits); construction starts and pauses until you can pay."
        }
        return "Build \(item.displayName) (\(item.cost) cr)"
    }
}

// MARK: - Options popover

/// The Options button's content: the scenario chooser, the game speed, the game toggles (fog, health bars,
/// AI fog, force-minimap, unit limit, …) — the same `DebugPanel` controls — plus a link to the macOS Settings
/// window (audio). This is the only place the scenario is chosen now (there's no window toolbar).
struct OptionsPopover: View {
    @State var model: GameModel
    @State private var showScenario = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("Scenario") {
                    Button {
                        showScenario = true
                    } label: {
                        Label(model.scenarioTitle, systemImage: "map")
                    }
                    .disabled(model.assets.scenarioNames.isEmpty)
                    .popover(isPresented: $showScenario, arrowEdge: .leading) {
                        ScenarioPicker(model: model, isPresented: $showScenario)
                    }
                }
                Picker("Game speed", selection: Binding(get: { model.gameSpeed }, set: { model.gameSpeed = $0 })) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .frame(height: 120)
            Divider()
            DebugPanel(model: model)
            #if os(macOS)
                // The audio settings live in the macOS `Settings` scene (⌘,); iOS has no such window.
                Divider()
                HStack {
                    SettingsLink { Label("Settings…", systemImage: "slider.horizontal.3") }
                    Spacer()
                }
                .padding(10)
            #endif
        }
        .frame(width: 320, height: 540)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.headline)
            Text(blockers.isEmpty ? "Available to build." : "Needs:").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(blockers.enumerated()), id: \.offset) { _, blocker in
                Label(blocker.summary, systemImage: icon(for: blocker)).font(.callout)
            }
        }
        .padding(14).frame(minWidth: 160, alignment: .leading)
    }

    private func icon(for blocker: BuildBlocker) -> String {
        switch blocker {
            case .campaign: "calendar"
            case .structure: "building.2.fill"
            case .upgradeLevel: "arrow.up.circle"
        }
    }
}
