import SpriteKit
import SwiftUI

/// The map window: a SpriteKit view filling the resizable window, with a toolbar to pick a scenario
/// and set the 1×–16× scale.
struct ContentView: View {
    @State
    var model: MapModel
    @State
    private var showInspector = true

    private let scales = [ 1, 2, 4, 8, 16 ]

    var body: some View {
        SpriteView(scene: model.scene, options: [ .ignoresSiblingOrder ])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .inspector(isPresented: $showInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Menu(model.currentScenario ?? "Scenario") {
                        ForEach(model.assets.scenarioNames, id: \.self) { name in
                            Button(name) { model.load(name) }
                        }
                    }
                    .disabled(model.assets.scenarioNames.isEmpty)
                }
                ToolbarItem(placement: .automatic) {
                    Picker("Scale", selection: $model.scale) {
                        ForEach(scales, id: \.self) { Text("\($0)×").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .automatic) {
                    Toggle("Fog", isOn: $model.showFog)
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help("Toggle the properties panel")
                }
            }
            .overlay(alignment: .top) {
                if let error = model.assets.error, !error.isEmpty {
                    Text(error).font(.callout).padding(8).background(.red.opacity(0.8)).foregroundStyle(.white)
                }
            }
    }
}
