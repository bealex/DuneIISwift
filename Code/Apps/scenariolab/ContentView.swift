import DuneIIScenarios
import SpriteKit
import SwiftUI

/// The scenario-lab window: a SpriteKit view of the 8×8 region with a toolbar to pick the scenario,
/// the two unit types, the zoom, regenerate the terrain, and pause/resume.
struct ContentView: View {
    @State var model: ScenarioLabModel

    private let scales = [1, 2, 4, 8, 16]
    private let speeds = Array(1 ... 10)

    var body: some View {
        // The 8×8 region is `sidePx` game pixels; at zoom `scale` it occupies `sidePx × scale` screen
        // points — a fixed square, centred on black, so it's never squished and stays point-to-pixel.
        let dim = CGFloat(ScenarioImageBuilder.sidePx * model.scale)
        ZStack {
            Color.black
            SpriteView(scene: model.scene, options: [.ignoresSiblingOrder])
                .frame(width: dim, height: dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Scenario", selection: $model.kind) {
                    ForEach(ScenarioKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            ToolbarItem(placement: .automatic) {
                Picker("Unit 1", selection: $model.unit1) {
                    ForEach(model.selectableUnits, id: \.self) { Text(model.name($0)).tag($0) }
                }
            }
            ToolbarItem(placement: .automatic) {
                Picker("Unit 2", selection: $model.unit2) {
                    ForEach(model.selectableUnits, id: \.self) { Text(model.name($0)).tag($0) }
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { model.regenerate() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Regenerate terrain")
            }
            ToolbarItem(placement: .automatic) {
                Button { model.running.toggle() } label: {
                    Image(systemName: model.running ? "pause.fill" : "play.fill")
                }
                .help(model.running ? "Pause" : "Run")
            }
            ToolbarItem(placement: .automatic) {
                Picker("Speed", selection: $model.speed) {
                    ForEach(speeds, id: \.self) { Text("\($0)×").tag($0) }
                }
                .help("Simulation speed (ticks per frame)")
            }
            ToolbarItem(placement: .automatic) {
                Picker("Scale", selection: $model.scale) {
                    ForEach(scales, id: \.self) { Text("\($0)×").tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .overlay(alignment: .top) {
            if let error = model.assets.error, !error.isEmpty {
                Text(error).font(.callout).padding(8).background(.red.opacity(0.85)).foregroundStyle(.white)
            }
        }
    }
}
