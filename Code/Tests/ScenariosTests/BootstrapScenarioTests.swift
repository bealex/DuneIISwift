import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
import DuneIIWorld
@testable import DuneIIScenarios

/// The shared bootstrap scenario `.INI` loads through our engine: terrain generated from `[MAP] Seed`
/// via `Map_CreateLandscape` (the real generator — with partial transition tiles, not a tile-by-tile
/// pick), and the `[UNITS]` placed. This is the same file the OpenDUNE oracle will load for the golden.
@Suite("Bootstrap scenario .INI")
struct BootstrapScenarioTests {
    private func load() throws -> GameState? {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { repo.deleteLastPathComponent() }   // Code/Tests/ScenariosTests → repo root
        guard let icon = try? Data(contentsOf: repo.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")),
              let iniData = try? Data(contentsOf: URL(fileURLWithPath: #filePath)
                  .deletingLastPathComponent().appendingPathComponent("Fixtures/bootstrap.ini"))
        else { return nil }
        var state = GameState()
        state.loadScenario(ini: Ini(iniData), iconMap: try IconMap(icon))
        return state
    }

    @Test("loads createLandscape terrain (varied, with transition tiles) and the placed unit")
    func loads() throws {
        guard let state = try load() else { return }

        // The generated landscape is varied — many distinct ground tiles, including the partial
        // sand/rock transition sprites the smoothing pass produces (not one flat tile).
        let distinct = Set(state.map.map { $0.groundTileID })
        #expect(distinct.count > 20)

        // The [UNITS] tank is placed at its packed position (1040 = 16,16), used, with real HP.
        let tank = state.units.first { $0.o.flags.contains(.used) }
        #expect(tank != nil)
        #expect(tank?.o.type == UInt8(UnitType.tank.rawValue))
        #expect(tank?.o.position.packed == 1040)
        #expect((tank?.o.hitpoints ?? 0) > 0)
    }
}
