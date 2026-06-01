import DuneIIContracts
import DuneIIWorld
import SwiftUI

/// The scenario chooser popover: house tabs across the top, the chosen house's scenarios grouped by campaign
/// level below. Picking one loads it — which also sets the campaign level that gates its tech tree (derived
/// from the mission number). Replaces the old two-control "scenario menu + campaign picker" toolbar.
struct ScenarioPicker: View {
    @State var model: GameModel
    @Binding var isPresented: Bool
    @State private var house: HouseID

    init(model: GameModel, isPresented: Binding<Bool>) {
        _model = State(initialValue: model)
        _isPresented = isPresented
        // Open on the current scenario's house (or Atreides if none/unparseable).
        let current = model.currentScenario.flatMap { ScenarioID(fileName: $0) }
        _house = State(initialValue: current?.house ?? .atreides)
    }

    var body: some View {
        let catalog = model.scenarioCatalog
        let houses = HouseID.allCases.filter { h in catalog.contains { $0.house == h } }
        let forHouse = catalog.filter { $0.house == house }
        let levels = Array(Set(forHouse.map(\.campaign))).sorted()
        VStack(spacing: 8) {
            Picker("House", selection: $house) {
                ForEach(houses, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(levels, id: \.self) { level in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Campaign \(level)")
                                .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            ForEach(forHouse.filter { $0.campaign == level }, id: \.self) { entry in
                                Button { model.load(entry.fileName); isPresented = false } label: {
                                    HStack {
                                        Text("Mission \(entry.mission)")
                                        Spacer()
                                        if entry.fileName == model.currentScenario {
                                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .frame(height: 360)
        }
        .padding(10)
        .frame(width: 230)
    }
}
