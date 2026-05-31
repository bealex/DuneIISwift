import SpriteKit
import SwiftUI

/// The main window: the map fills it (black where the world doesn't reach), with a toolbar to load a
/// scenario and toggle the floating tool windows. Pan/zoom + selection happen in the `GameScene` (mouse +
/// the +/- and arrow keys). The window is normally resizable + fullscreen-able; the tool windows float over
/// it (even in fullscreen) via the `ToolWindowManager`.
struct ContentView: View {
    @State var model: GameModel
    @State private var tools: ToolWindowManager
    @State private var openedDefaults = false

    init(model: GameModel) {
        _model = State(initialValue: model)
        _tools = State(initialValue: ToolWindowManager(model: model))
    }

    var body: some View {
        SpriteView(scene: model.scene, options: [.ignoresSiblingOrder])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Menu(model.currentScenario ?? "Scenario") {
                        ForEach(model.assets.scenarioNames, id: \.self) { name in Button(name) { model.load(name) } }
                    }
                    .disabled(model.assets.scenarioNames.isEmpty)
                }
                ToolbarItemGroup(placement: .automatic) {
                    ForEach(ToolKind.allCases) { kind in
                        Button { tools.toggle(kind) } label: { Image(systemName: kind.symbol) }
                            .help("Toggle the \(kind.title) window")
                            .foregroundStyle(model.openTools.contains(kind) ? Color.accentColor : Color.primary)
                    }
                }
            }
            .overlay(alignment: .top) {
                if let error = model.assets.error, !error.isEmpty {
                    Text(error).font(.callout).padding(8).background(.red.opacity(0.85)).foregroundStyle(.white)
                }
            }
            .onAppear { if !openedDefaults { tools.openDefaults(); openedDefaults = true } }
    }
}
