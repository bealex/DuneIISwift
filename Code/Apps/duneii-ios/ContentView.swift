import DuneIIClient
import SpriteKit
import SwiftUI

/// The iOS root view: the SpriteKit map fills the screen with the shared `GameSidebar` on the trailing edge —
/// the same layout as the macOS app, minus the window toolbar (which macOS already dropped). Touch input is
/// handled inside `GameScene` (`#if os(iOS)`): tap to select/place, drag to pan, pinch to zoom, long-press to
/// order. Save/Load use a simple quicksave slot in the app's Documents directory.
struct ContentView: View {
    @State
    var model: GameModel
    @State
    private var notice: String?

    var body: some View {
        HStack(spacing: 0) {
            SpriteView(scene: model.scene, options: [ .ignoresSiblingOrder ])
                .background(.black)
                .ignoresSafeArea()
                .overlay(alignment: .topLeading) {
                    MapStatsOverlay(model: model)
                        .padding(.top, 12).padding(.leading, 16)
                }
                .overlay(alignment: .topTrailing) {
                    MapControlsOverlay(model: model, onSave: saveGame, onLoad: loadGame)
                        .padding(.top, 12).padding(.trailing, 16)
                }
                // The long-press building context popup anchors to a point in this (map) coordinate space.
                .overlay(alignment: .topLeading) { BuildingMenuAnchor(model: model) }
                .overlay(alignment: .top) {
                    if let error = model.assets.error, !error.isEmpty {
                        Text(error).font(.callout).padding(8)
                            .background(.red.opacity(0.85)).foregroundStyle(.white)
                    }
                }
                .overlay {
                    if let outcome = model.outcomeText {
                        Text(outcome).font(.system(size: 56, weight: .heavy))
                            .foregroundStyle(outcome == "Victory" ? .green : .red)
                            .padding(40).background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .overlay(alignment: .bottom) {
                    if let notice {
                        Label(notice, systemImage: "exclamationmark.bubble.fill")
                            .font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.yellow)
                            .padding(.bottom, 24).transition(.opacity).id(notice)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: notice)

            GameSidebar(model: model, fullScreen: true)
        }
    }

    /// Quicksave to the app's Documents directory (named after the current scenario).
    private func saveGame() {
        let url = documentsURL.appending(path: "\(model.currentScenario.map(stripExtension) ?? "game").duneiisave")
        flash(model.saveGame(to: url) ? "Game saved" : "Save failed")
    }

    /// Load the most recently written quicksave.
    private func loadGame() {
        let saves =
            (try? FileManager.default.contentsOfDirectory(
                at: documentsURL,
                includingPropertiesForKeys: [ .contentModificationDateKey ]
            )) ?? []
        let latest =
            saves
            .filter { $0.pathExtension == "duneiisave" }
            .max { date($0) < date($1) }
        guard let latest else { flash("No saved games"); return }

        flash(model.loadGame(from: latest) ? "Game loaded" : "Load failed")
    }

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func date(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [ .contentModificationDateKey ]).contentModificationDate) ?? .distantPast
    }

    private func stripExtension(_ name: String) -> String { (name as NSString).deletingPathExtension }

    private func flash(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(2)); if notice == message { notice = nil }
        }
    }
}
