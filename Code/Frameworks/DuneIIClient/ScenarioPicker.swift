import DuneIIContracts
import DuneIIWorld
import SwiftUI

/// The scenario chooser popover: house tabs across the top, the chosen house's scenarios grouped by campaign
/// level below. Picking one loads it — which also sets the campaign level that gates its tech tree (derived
/// from the mission number). Replaces the old two-control "scenario menu + campaign picker" toolbar.
public struct ScenarioPicker: View {
    @State
    var model: GameModel
    @Environment(\.dismiss)
    private var dismiss
    @State
    private var house: HouseID

    public init(model: GameModel) {
        _model = State(initialValue: model)
        // Open on the current scenario's house (or Atreides if none/unparseable).
        let current = model.currentScenario.flatMap { ScenarioID(fileName: $0) }
        _house = State(initialValue: current?.house ?? .atreides)
    }

    public var body: some View {
        let catalog = model.scenarioCatalog
        let houses = HouseID.allCases.filter { h in catalog.contains { $0.house == h } }
        let forHouse = catalog.filter { $0.house == house }
        let levels = Array(Set(forHouse.map(\.campaign))).sorted()
        List {
            Section {
                Picker("House", selection: $house) {
                    ForEach(houses, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ForEach(levels, id: \.self) { level in
                Section("Campaign \(level)") {
                    ForEach(forHouse.filter { $0.campaign == level }, id: \.self) { entry in
                        Button {
                            model.load(entry.fileName); dismiss()
                        } label: {
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
        #if os(iOS)
            // Pushed full-screen inside the Options NavigationStack — fill the width (a fixed-width popover hid
            // most of the content on a phone).
            .navigationTitle("Scenario")
            .navigationBarTitleDisplayMode(.inline)
        #else
            .gamePopover(width: 300, maxHeight: 460)
        #endif
    }
}
