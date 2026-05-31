import AppKit
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
                ToolbarItem(placement: .automatic) {
                    Picker("Speed", selection: Binding(get: { model.gameSpeed }, set: { model.gameSpeed = $0 })) {
                        Text("0.5×").tag(0.5)
                        Text("1×").tag(1.0)
                        Text("2×").tag(2.0)
                        Text("4×").tag(4.0)
                    }
                    .pickerStyle(.menu)
                    .help("Game speed")
                }
                ToolbarItemGroup(placement: .automatic) {
                    ForEach(ToolKind.allCases) { kind in
                        Button { tools.toggle(kind) } label: { Image(systemName: kind.symbol) }
                            .help("Toggle the \(kind.title) window")
                            .foregroundStyle(model.openTools.contains(kind) ? Color.accentColor : Color.primary)
                    }
                }
            }
            .background(WindowAccessor { window in tools.attachToMain(window) })
            .overlay(alignment: .top) {
                if let error = model.assets.error, !error.isEmpty {
                    Text(error).font(.callout).padding(8).background(.red.opacity(0.85)).foregroundStyle(.white)
                }
            }
            .onAppear { if !openedDefaults { tools.openDefaults(); openedDefaults = true } }
    }
}

/// Reaches the SwiftUI window's backing `NSWindow` (for child-window parenting + frame autosave). Fires the
/// callback once the view is in a window, and again on updates (the callback is idempotent).
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onResolve(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let window = nsView.window { onResolve(window) } }
    }
}
