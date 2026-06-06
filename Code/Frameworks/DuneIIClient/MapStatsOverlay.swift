import SwiftUI

/// The player's credits + power, overlaid on the top-left of the map (moved off the sidebar header). Drawn
/// with a heavy drop shadow so the digits stay legible over any terrain, and non-interactive so it never
/// eats a tap/pan on the map beneath it.
public struct MapStatsOverlay: View {
    var model: GameModel

    public init(model: GameModel) { self.model = model }

    public var body: some View {
        let economy = model.economy.first { $0.isPlayer }
        let powerOK = economy.map { $0.power >= $0.powerUsed } ?? true
        HStack(spacing: 14) {
            Label("\(model.playerCredits)", systemImage: "dollarsign.circle.fill")
                .foregroundStyle(.yellow)
            Label("\(economy?.power ?? 0)/\(economy?.powerUsed ?? 0)", systemImage: "bolt.fill")
                .foregroundStyle(powerOK ? Color.white : Color.red)
                .help("Power produced / consumed")
        }
        .font(.title3.bold().monospacedDigit())
        // Two stacked shadows form a dark halo, so it reads on light sand as well as dark rock.
        .shadow(color: .black, radius: 1)
        .shadow(color: .black.opacity(0.8), radius: 4)
        .allowsHitTesting(false)
    }
}
