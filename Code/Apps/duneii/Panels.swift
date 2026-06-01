import DuneIIInput
import DuneIISimulation
import DuneIIWorld
import SwiftUI

/// The selected unit/building's properties + the commands available to it (player-owned units only).
struct InspectorPanel: View {
    @State var model: GameModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let s = model.selection {
                    HStack {
                        Image(systemName: s.kind == .unit ? "shippingbox.fill" : "building.2.fill").foregroundStyle(.secondary)
                        Text(s.name).font(.title2.bold())
                        if model.selectedUnitCount > 1 {
                            Text("×\(model.selectedUnitCount)").font(.caption.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.25), in: Capsule())
                        }
                        if s.isPlayer { Text("yours").font(.caption).foregroundStyle(.green) }
                    }
                    // What it's doing right now (a unit's order / a structure's activity).
                    Label(s.state, systemImage: "waveform.path.ecg")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow { Text("House").foregroundStyle(.secondary); Text(s.house) }
                        GridRow { Text("Tile").foregroundStyle(.secondary); Text("(\(s.tileX), \(s.tileY))") }
                    }.font(.callout)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text("Health").foregroundStyle(.secondary); Spacer(); Text("\(s.hitpoints) / \(s.hitpointsMax)").monospacedDigit() }
                        ProgressView(value: Double(s.hitpoints), total: Double(max(s.hitpointsMax, 1)))
                            .tint(tint(s.hitpoints, s.hitpointsMax))
                    }.font(.callout)
                    if !s.unitActions.isEmpty {
                        Divider()
                        Text("Commands").font(.headline)
                        ForEach(s.unitActions, id: \.self) { action in
                            Button { model.issue(action) } label: {
                                Label(action.label, systemImage: action.type.systemImage)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .tint(action.targeted && model.pendingOrder == action.type.orderKind ? .accentColor : nil)
                        }
                        if let p = model.pendingOrder {
                            Label("Click a target to \(p.verb)…", systemImage: "scope").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    structureSection()
                    superWeaponSection()
                    buildSection()
                } else if let t = model.tileInfo {
                    tileSection(t)
                } else {
                    ContentUnavailableView("No selection", systemImage: "cursorarrow.rays",
                                           description: Text("Left-click a tile to inspect it,\na unit or building to select it."))
                        .padding(.top, 30)
                }
                Spacer(minLength: 0)
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tint(_ hp: Int, _ max: Int) -> Color {
        let f = max > 0 ? Double(hp) / Double(max) : 1
        return f > 0.66 ? .green : (f > 0.33 ? .yellow : .red)
    }

    /// A bare map tile's parameters — shown when the player left-clicks a tile with no unit/structure on it.
    @ViewBuilder private func tileSection(_ t: TileInfo) -> some View {
        HStack {
            Image(systemName: "squareshape.split.3x3").foregroundStyle(.secondary)
            Text(t.landscape).font(.title2.bold())
        }
        Label("Tile (\(t.tileX), \(t.tileY))", systemImage: "mappin.and.ellipse")
            .font(.callout.weight(.semibold)).foregroundStyle(.tint)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow { Text("Packed").foregroundStyle(.secondary); Text("\(t.packed)").monospacedDigit() }
            GridRow { Text("Ground id").foregroundStyle(.secondary); Text("\(t.groundTileID)").monospacedDigit() }
            GridRow { Text("Overlay id").foregroundStyle(.secondary); Text("\(t.overlayTileID)").monospacedDigit() }
            if t.isSpice {
                GridRow { Text("Spice").foregroundStyle(.secondary); Text(t.landscape == "Thick spice" ? "thick" : "yes").foregroundStyle(.orange) }
            }
            if let owner = t.owner {
                GridRow { Text("Owner").foregroundStyle(.secondary); Text(owner) }
            }
            GridRow { Text("Fog").foregroundStyle(.secondary); Text(t.isUnveiled ? "revealed" : "hidden") }
            GridRow { Text("Buildable").foregroundStyle(.secondary); Text(t.isBuildable ? "yes" : "no") }
        }.font(.callout)
    }

    /// Repair / Upgrade (toggle) for the selected player building, plus a starport's CHOAM order list.
    @ViewBuilder private func structureSection() -> some View {
        if let a = model.structureActions {
            Divider()
            HStack {
                Button { model.repairSelected() } label: {
                    Label(a.isRepairing ? "Repairing…" : "Repair", systemImage: "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(a.isRepairing ? .accentColor : nil)
                .disabled(!a.canRepair && !a.isRepairing)

                Button { model.upgradeSelected() } label: {
                    Label(a.isUpgrading ? "Upgrading…" : "Upgrade", systemImage: "arrow.up.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(a.isUpgrading ? .accentColor : nil)
                .disabled(!a.canUpgrade && !a.isUpgrading)
            }
            if !model.starportStock.isEmpty {
                Text("Order (Starport)").font(.headline).padding(.top, 4)
                VStack(spacing: 4) {
                    ForEach(model.starportStock, id: \.objectType) { item in
                        Button { model.orderFromStarport(item.objectType) } label: {
                            HStack {
                                Text(item.displayName)
                                Spacer()
                                Text("\(item.cost) cr").monospacedDigit()
                                    .foregroundStyle(item.cost > model.playerCredits ? Color.red : Color.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled(item.cost > model.playerCredits)
                    }
                }
            }
        }
    }

    /// The palace super-weapon launch: a button (enabled when the countdown has recharged). The death-hand
    /// then arms a target click; the Fremen call / saboteur fire in place.
    @ViewBuilder private func superWeaponSection() -> some View {
        if let sw = model.superWeapon {
            Divider()
            Text("Palace").font(.headline)
            Button { model.launchSuperWeapon() } label: {
                Label(sw.ready ? sw.title : "Recharging…", systemImage: sw.systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.missileTargeting != nil ? .orange : .red)
            .disabled(!sw.ready)
            if model.missileTargeting != nil {
                Label("Click a target for the Death Hand…", systemImage: "scope")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The factory build section: a buildable-item selector, or — once building — a progress bar with
    /// Cancel and (a finished construction-yard structure) a "Place it" button. Shown for a player factory.
    @ViewBuilder private func buildSection() -> some View {
        if model.isFactorySelected {
            Divider()
            Text("Build").font(.headline)
            if let bs = model.buildProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(bs.displayName).bold()
                        Spacer()
                        if bs.isReady { Text("Ready").font(.caption).foregroundStyle(.green) }
                        else if bs.onHold { Text("On hold").font(.caption).foregroundStyle(.orange) }
                    }
                    ProgressView(value: bs.progress).tint(bs.onHold ? .orange : .accentColor)
                    HStack {
                        if bs.isReady && bs.isStructure {
                            Button { model.beginPlacement() } label: { Label("Place it", systemImage: "mappin.and.ellipse") }
                                .buttonStyle(.borderedProminent)
                        } else if bs.isReady {
                            Label("Deploying…", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.green)
                        }
                        Button(role: .destructive) { model.cancelBuild() } label: { Label("Cancel", systemImage: "xmark") }
                            .buttonStyle(.bordered)
                    }
                    if model.placement != nil {
                        Label("Click a spot to place · Esc / right-click cancels", systemImage: "hand.tap")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if model.buildOptions.isEmpty {
                Text("Nothing available to build.").font(.caption).foregroundStyle(.secondary)
            } else {
                // Every item the factory could ever build; locked ones (missing prerequisites / campaign /
                // upgrade) are greyed-out with a tooltip listing what's missing.
                VStack(spacing: 4) {
                    ForEach(model.buildOptions, id: \.item.objectType) { option in
                        let item = option.item
                        let tooLowCredits = option.isAvailable && item.cost > model.playerCredits
                        Button { model.startBuild(item.objectType) } label: {
                            HStack {
                                Text(item.displayName)
                                if !option.isAvailable {
                                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(item.cost) cr").monospacedDigit()
                                    .foregroundStyle(tooLowCredits ? Color.red : Color.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!option.isAvailable || tooLowCredits)
                        .help(buildHelp(option))
                    }
                }
            }
        }
    }

    /// The tooltip for a build button: what an item costs, and — when locked — what's missing to unlock it
    /// (prerequisite structures, campaign level, factory upgrade), or a low-credits note when it's affordable
    /// only once you have more money.
    private func buildHelp(_ option: BuildOption) -> String {
        let item = option.item
        if !option.isAvailable {
            return "Requires: " + option.blockers.map(\.summary).joined(separator: ", ")
        }
        if item.cost > model.playerCredits {
            return "Costs \(item.cost) cr — need \(item.cost - model.playerCredits) more."
        }
        return "Build \(item.displayName) (\(item.cost) cr)"
    }
}

/// Per-house economy: credits, storage, and power balance. Shows all houses or only the player's
/// (the Debug window's toggle).
struct EconomyPanel: View {
    @State var model: GameModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.economy.isEmpty {
                    Text("No active houses.").foregroundStyle(.secondary).padding()
                }
                ForEach(model.economy, id: \HouseEconomy.house) { (e: HouseEconomy) in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(e.house).font(.headline)
                            if e.isPlayer { Text("you").font(.caption).foregroundStyle(.green) }
                        }
                        HStack { Text("Credits").foregroundStyle(.secondary); Spacer(); Text("\(e.credits) / \(e.storage)").monospacedDigit() }
                        HStack {
                            Text("Power").foregroundStyle(.secondary); Spacer()
                            Text("\(e.power) − \(e.powerUsed)").monospacedDigit()
                                .foregroundStyle(e.power >= e.powerUsed ? Color.primary : Color.red)
                        }
                        ProgressView(value: Double(e.credits), total: Double(max(e.storage, 1)))
                    }
                    .font(.callout)
                    .padding(8)
                    .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer(minLength: 0)
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Debug controls: fog, whose economy to show, and the per-unit health/state overlay.
struct DebugPanel: View {
    @State var model: GameModel

    var body: some View {
        Form {
            Toggle("Fog of war", isOn: Binding(get: { model.showFog }, set: { model.showFog = $0 }))
            Toggle("AI fog of war", isOn: Binding(get: { model.aiFogOfWar }, set: { model.aiFogOfWar = $0 }))
            if model.aiFogOfWar {
                Text("The AI only attacks after you make contact (its units/your scouts sighting each other). Applies immediately, even mid-game.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Follow unit limit", isOn: Binding(get: { model.enforceUnitLimit }, set: { model.enforceUnitLimit = $0 }))
            if !model.enforceUnitLimit {
                Text("Unit cap (scenario MaxUnit) ignored — build past it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Play indefinitely", isOn: Binding(get: { model.playIndefinitely }, set: { model.playIndefinitely = $0 }))
            if model.playIndefinitely {
                Text("Victory/defeat is disabled — the game never ends. Turning it on clears any current outcome.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Minimap (force on)", isOn: Binding(get: { model.forceMinimap }, set: { model.forceMinimap = $0 }))
            if !model.forceMinimap {
                Text("Off: the minimap obeys radar (needs an outpost + power). On: always shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Show all economies", isOn: Binding(get: { model.showAllEconomies }, set: { model.showAllEconomies = $0 }))
            Toggle("Health bars (units + buildings)", isOn: Binding(get: { model.showHealthOverlay }, set: { model.showHealthOverlay = $0 }))
            Toggle("Music", isOn: Binding(get: { model.musicEnabled }, set: { model.musicEnabled = $0 }))
            LabeledContent("Player house", value: model.playerHouse.displayName)
            LabeledContent("Scenario", value: model.scenarioTitle)
            LabeledContent("Campaign level", value: "\(model.campaignLevel)")
        }
        .formStyle(.grouped)
    }
}

extension PanelAction {
    /// The button caption — the original action name (`ActionInfo`) with its keyboard shortcut appended.
    var label: String {
        if let s = type.shortcut { return "\(ActionInfo[type].name) (\(s))" }
        return ActionInfo[type].name
    }
}

extension ActionType {
    /// The keyboard shortcut letter for this action (matches `GameScene.keyDown`), or `nil` for non-player
    /// actions. `r` = Return (per the harvester); Retreat is `e`, Guard `g`, Deploy `d`, Sabotage `b`,
    /// Destruct `x` (Stop is the universal `s`, handled separately).
    var shortcut: String? {
        switch self {
            case .attack: "A"; case .move: "M"; case .harvest: "H"; case .return: "R"
            case .retreat: "E"; case .guard_, .areaGuard: "G"; case .deploy: "D"
            case .sabotage: "B"; case .destruct: "X"
            default: nil
        }
    }

    /// The matching armed-order kind for a targeted action, else `nil` (an immediate `.unit` action).
    var orderKind: OrderKind? {
        switch self {
            case .attack: .attack; case .move: .move; case .harvest: .harvest; case .retreat: .retreat
            default: nil
        }
    }

    /// SF Symbol for the action-panel button.
    var systemImage: String {
        switch self {
            case .attack: "target"; case .move: "arrow.up.right"; case .harvest: "leaf"
            case .retreat: "arrow.uturn.left"; case .guard_, .areaGuard: "shield"
            case .return: "arrow.down.left.circle"; case .stop: "stop.fill"
            case .deploy: "shippingbox"; case .destruct: "burst"; case .sabotage: "bolt.trianglebadge.exclamationmark"
            case .ambush: "eye.slash"; case .hunt: "scope"; case .die: "xmark"
        }
    }
}

/// Presentation labels for the unit orders (the keyboard shortcuts are `m`/`a`/`h`/`r`, plus `s` for stop).
extension OrderKind {
    var label: String { switch self { case .move: "Move"; case .attack: "Attack"; case .harvest: "Harvest"; case .retreat: "Retreat" } }
    var verb: String { switch self { case .move: "move"; case .attack: "attack"; case .harvest: "harvest"; case .retreat: "retreat" } }
    var shortcut: String { switch self { case .move: "M"; case .attack: "A"; case .harvest: "H"; case .retreat: "R" } }
    var systemImage: String {
        switch self { case .move: "arrow.up.right"; case .attack: "target"; case .harvest: "leaf"; case .retreat: "arrow.uturn.left" }
    }
}
