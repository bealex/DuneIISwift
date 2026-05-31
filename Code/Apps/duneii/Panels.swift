import DuneIIInput
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
                                Label(kind == .move ? "Move" : "Attack", systemImage: kind == .move ? "arrow.up.right" : "target")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered).tint(model.pendingOrder == kind ? .accentColor : nil)
                        }
                        if s.canStop {
                            Button { model.stopSelected() } label: { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity, alignment: .leading) }
                                .buttonStyle(.bordered)
                        }
                        if let p = model.pendingOrder {
                            Label("Click a target to \(p == .move ? "move" : "attack")…", systemImage: "scope").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Deselect", role: .cancel) { model.deselect() }.controlSize(.small)
                    }
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
            Toggle("Health bars over units", isOn: Binding(get: { model.showHealthOverlay }, set: { model.showHealthOverlay = $0 }))
            if model.showHealthOverlay {
                LabeledContent("State chip") {
                    HStack(spacing: 8) {
                        chip(.green, "Move"); chip(.red, "Attack"); chip(.blue, "Guard"); chip(.orange, "Harvest")
                    }
                }
                Text("Idle units show no chip.").font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Player house", value: model.playerHouse.displayName)
            LabeledContent("Scenario", value: model.currentScenario ?? "—")
        }
        .formStyle(.grouped)
    }

    private func chip(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2)
        }
    }
}
