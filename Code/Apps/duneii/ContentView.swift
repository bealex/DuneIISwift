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
        MapSpriteView(scene: model.scene)
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
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.bubble.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.yellow)
                        .padding(.bottom, 24)
                        .transition(.opacity)
                        .id(notice)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.notice)
            .onAppear { if !openedDefaults { tools.openDefaults(); openedDefaults = true } }
    }
}

/// Hosts the map `GameScene` in an `SKView` that **accepts the first mouse** — so a click on the map is
/// delivered to the scene even when the main window isn't key (a floating tool window has focus). SwiftUI's
/// stock `SpriteView` returns `acceptsFirstMouse == false`, which swallows that first click to merely focus
/// the window. (The scene is `.resizeFill`, so the view just presents it and resizes do the rest.)
struct MapSpriteView: NSViewRepresentable {
    let scene: SKScene

    func makeNSView(context: Context) -> SKView {
        let view = FirstMouseSKView()
        view.ignoresSiblingOrder = true
        view.presentScene(scene)
        return view
    }

    func updateNSView(_ view: SKView, context: Context) {
        if view.scene !== scene { view.presentScene(scene) }
    }
}

/// An `SKView` that takes the first click in an inactive window (rather than just activating it), so map
/// taps work while a tool window is focused. It also **forwards middle-button (`otherMouse`) events** to the
/// scene: `SKView` relays `mouseDown`/`rightMouseDown` to its scene but not `otherMouse*`, so without this the
/// scene's middle-drag pan / middle-click recentre never fired.
final class FirstMouseSKView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func otherMouseDown(with event: NSEvent) { scene?.otherMouseDown(with: event) }
    override func otherMouseDragged(with event: NSEvent) { scene?.otherMouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { scene?.otherMouseUp(with: event) }
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
