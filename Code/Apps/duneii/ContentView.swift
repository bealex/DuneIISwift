import AppKit
import DuneIIClient
import SpriteKit
import SwiftUI

/// The main window: the map fills it (black where the world doesn't reach), with a toolbar to load a
/// scenario and toggle the floating tool windows. Pan/zoom + selection happen in the `GameScene` (mouse +
/// the +/- and arrow keys). The window is normally resizable + fullscreen-able; the tool windows float over
/// it (even in fullscreen) via the `ToolWindowManager`.
struct ContentView: View {
    @State var model: GameModel
    @State private var tools: ToolWindowManager
    @State private var showScenarioPicker = false
    @State private var showDebug = false
    @State private var isFullScreen = false

    init(model: GameModel) {
        _model = State(initialValue: model)
        _tools = State(initialValue: ToolWindowManager(model: model))
    }

    var body: some View {
        HStack(spacing: 0) {
            mapArea
            Divider()
            GameSidebar(model: model, fullScreen: isFullScreen,
                        onSave: { presentSaveGame(model) }, onLoad: { presentLoadGame(model) })
        }
        // Note: no `.ignoresSafeArea()` — that drew the map up *under* the toolbar (it sits in the
        // title-bar safe area), so the map now fills the area below the toolbar.
        .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { showScenarioPicker.toggle() } label: {
                        Label(model.scenarioTitle, systemImage: "map")
                    }
                    .disabled(model.assets.scenarioNames.isEmpty)
                    .help("Choose a scenario — by house, grouped by campaign level (which gates the tech tree).")
                    .popover(isPresented: $showScenarioPicker, arrowEdge: .bottom) {
                        ScenarioPicker(model: model, isPresented: $showScenarioPicker)
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("Save Game…") { saveGame() }
                        Button("Load Game…") { loadGame() }
                    } label: { Image(systemName: "doc.badge.gearshape") }
                    .help("Save / load the game")
                }
                ToolbarItem(placement: .automatic) {
                    Button { model.togglePause() } label: {
                        Image(systemName: model.paused ? "play.fill" : "pause.fill")
                    }
                    .help(model.paused ? "Resume (space)" : "Pause (space)")
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
                    .disabled(model.paused)
                }
                ToolbarItem(placement: .automatic) {
                    Button { showDebug.toggle() } label: { Image(systemName: "ladybug") }
                        .help("Debug controls (fog, health bars, economy, …)")
                        .popover(isPresented: $showDebug, arrowEdge: .bottom) {
                            DebugPanel(model: model).frame(width: 320, height: 380)
                        }
                }
            }
            .background(WindowAccessor { window in tools.attachToMain(window) })
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = true }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = false }
    }

    /// The map fills the window to the left of the sidebar (black where the world doesn't reach); the
    /// transient banners (asset error, victory/defeat, notices) are overlaid on it, not the sidebar.
    private var mapArea: some View {
        MapSpriteView(scene: model.scene)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .overlay(alignment: .top) {
                if let error = model.assets.error, !error.isEmpty {
                    Text(error).font(.callout).padding(8).background(.red.opacity(0.85)).foregroundStyle(.white)
                }
            }
            .overlay {
                if let outcome = model.outcomeText {
                    VStack(spacing: 6) {
                        Text(outcome).font(.system(size: 56, weight: .heavy))
                            .foregroundStyle(outcome == "Victory" ? .green : .red)
                        Text("Pick a scenario or load a save to play again.")
                            // On the dark panel, `.secondary` is near-invisible — use a light tint instead.
                            .font(.callout).foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(40)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: model.outcomeText)
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
    }

    private func saveGame() { presentSaveGame(model) }
    private func loadGame() { presentLoadGame(model) }
}

/// Present a save panel and write the current game (our `SaveGame` binary). A top-level function so both the
/// toolbar button and the File-menu command (`DuneIIApp.commands`) can invoke the same flow.
@MainActor func presentSaveGame(_ model: GameModel) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(model.currentScenario ?? "game").duneiisave"
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url { model.saveGame(to: url) }
}

/// Present an open panel and restore the chosen save. Shared by the toolbar button and the File-menu command.
@MainActor func presentLoadGame(_ model: GameModel) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url { model.loadGame(from: url) }
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
