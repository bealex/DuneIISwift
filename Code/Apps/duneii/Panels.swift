import DuneIIInput
import DuneIISimulation
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
                    if !s.commands.isEmpty || s.canStop {
                        Divider()
                        Text("Commands").font(.headline)
                        ForEach(s.commands, id: \.self) { kind in
                            Button { model.arm(kind) } label: {
                                Label("\(kind.label) (\(kind.shortcut))", systemImage: kind.systemImage)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered).tint(model.pendingOrder == kind ? .accentColor : nil)
                        }
                        if s.canStop {
                            Button { model.stopSelected() } label: { Label("Stop (S)", systemImage: "stop.fill").frame(maxWidth: .infinity, alignment: .leading) }
                                .buttonStyle(.bordered)
                        }
                        if let p = model.pendingOrder {
                            Label("Click a target to \(p.verb)…", systemImage: "scope").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Deselect", role: .cancel) { model.deselect() }.controlSize(.small)
                    }
                    buildSection()
                } else {
                    ContentUnavailableView("No selection", systemImage: "cursorarrow.rays",
                                           description: Text("Left-click a unit or building.\nRight-click to move/attack."))
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
            } else if model.buildables.isEmpty {
                Text("Nothing available to build.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(model.buildables, id: \.objectType) { item in
                        Button { model.startBuild(item.objectType) } label: {
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
            Toggle("Show all economies", isOn: Binding(get: { model.showAllEconomies }, set: { model.showAllEconomies = $0 }))
            Toggle("Health bars (units + buildings)", isOn: Binding(get: { model.showHealthOverlay }, set: { model.showHealthOverlay = $0 }))
            if model.showHealthOverlay {
                LabeledContent("State chip") {
                    HStack(spacing: 8) {
                        legend(RightTriangle(), .green, "Move"); legend(Diamond(), .red, "Attack")
                        legend(Rectangle(), .blue, "Guard"); legend(Circle(), .orange, "Harvest")
                    }
                }
                Text("Idle units show no chip.").font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Player house", value: model.playerHouse.displayName)
            LabeledContent("Scenario", value: model.currentScenario ?? "—")
        }
        .formStyle(.grouped)
    }

    private func legend(_ shape: some Shape, _ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            shape.fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2)
        }
    }
}

/// A right-pointing triangle (the "move" state chip), matching `GameScene.chipStyle`.
struct RightTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
        return p
    }
}

/// A diamond (the "attack" state chip).
struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.closeSubpath()
        return p
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
