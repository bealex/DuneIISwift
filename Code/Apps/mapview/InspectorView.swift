import DuneIIInput
import SwiftUI

/// The selection inspector: the properties of the selected unit/building and the commands available to it.
/// A Contracts-bound panel — it reads the scene-published `SelectionInfo` from the model and calls back to
/// arm an order (Move/Attack), which the next map click targets, or Stop the unit immediately.
struct InspectorView: View {
    @State
    var model: MapModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let selection = model.selection {
                    header(selection)
                    Divider()
                    commands(selection)
                } else {
                    ContentUnavailableView {
                        Label("No selection", systemImage: "cursorarrow.rays")
                    } description: {
                        Text(
                            "Left-click a unit or building to select it.\nRight-click to move (open ground) or attack (an enemy)."
                        )
                    }
                    .padding(.top, 40)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 220)
    }

    @ViewBuilder private func header(_ s: SelectionInfo) -> some View {
        HStack {
            Image(systemName: s.kind == .unit ? "shippingbox.fill" : "building.2.fill")
                .foregroundStyle(.secondary)
            Text(s.name).font(.title2.bold())
        }
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("House").foregroundStyle(.secondary); Text(s.house)
            }
            GridRow {
                Text("Tile").foregroundStyle(.secondary); Text("(\(s.tileX), \(s.tileY))")
            }
        }
        .font(.callout)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Health").foregroundStyle(.secondary)
                Spacer()
                Text("\(s.hitpoints) / \(s.hitpointsMax)").monospacedDigit()
            }
            ProgressView(value: Double(s.hitpoints), total: Double(max(s.hitpointsMax, 1)))
                .tint(healthTint(s))
        }
        .font(.callout)
    }

    @ViewBuilder private func commands(_ s: SelectionInfo) -> some View {
        Text("Commands").font(.headline)
        if s.commands.isEmpty && !s.canStop {
            Text("No commands for this building.").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(s.commands, id: \.self) { kind in
            Button {
                model.arm(kind)
            } label: {
                Label(title(kind), systemImage: icon(kind)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(model.pendingOrder == kind ? .accentColor : nil)
        }
        if s.canStop {
            Button {
                model.stopSelected()
            } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
        if let pending = model.pendingOrder {
            Label("Click a target tile to \(title(pending).lowercased())…", systemImage: "scope")
                .font(.caption).foregroundStyle(.secondary)
        }
        Button("Deselect", role: .cancel) { model.deselect() }
            .controlSize(.small).padding(.top, 4)
    }

    private func title(_ k: OrderKind) -> String { k == .move ? "Move" : "Attack" }
    private func icon(_ k: OrderKind) -> String { k == .move ? "arrow.up.right" : "target" }
    private func healthTint(_ s: SelectionInfo) -> Color {
        let f = s.hitpointsMax > 0 ? Double(s.hitpoints) / Double(s.hitpointsMax) : 1
        return f > 0.66 ? .green : (f > 0.33 ? .yellow : .red)
    }
}
