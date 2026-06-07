import AppKit
import DuneIIContracts
import DuneIISimulation
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIIClient

/// A right-click on a player building opens its context popup with **full** information immediately: the
/// build list / structure actions are recomputed synchronously in `rightClickOpensBuildingMenu`, not a
/// throttled frame later. Previously a not-yet-selected building's popup opened showing the *prior*
/// selection's derived state until the next refresh. Skips without the install.
@MainActor
struct BuildingMenuInfoTests {
    private var installURL: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }  // Code/Tests/ClientTests/x.swift → repo
        let url = root.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test func rightClickPopulatesFactoryInfoImmediately() throws {
        guard let installURL else { print("building-menu-info: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL))  // loads the first scenario in init
        guard let sim = model.simulation else { Issue.record("no simulation after load"); return }

        let player = UInt8(model.playerHouse.rawValue)
        // The player's construction yard is always present at scenario start and is a buildable factory.
        guard let slot = sim.state.structures.firstIndex(where: {
            $0.o.flags.contains(.used)
                && $0.o.houseID == player
                && $0.o.type == UInt8(StructureType.constructionYard.rawValue)
        }) else {
            print("building-menu-info: no player construction yard in first scenario — skipped")
            return
        }

        let packed = sim.state.structures[slot].o.position.packed
        let tx = Int(packed % 64), ty = Int(packed / 64)

        // No units selected and the building was not previously selected → the popup must still open with its
        // build info already populated (the bug: it lagged a frame, so it opened empty / showing the old one).
        let opened = model.rightClickOpensBuildingMenu(tileX: tx, tileY: ty, at: CGPoint(x: 10, y: 10))
        #expect(opened, "right-click on the player construction yard should open its popup")
        #expect(model.buildingMenu != nil)
        #expect(model.selection?.kind == .structure)
        // Read by the popup — present now, without advancing a single frame.
        #expect(model.isFactorySelected, "the CY should be recognised as a factory immediately")
        #expect(!model.buildOptions.isEmpty, "the CY's build list should be populated immediately")
    }

    @Test func upgradeIsNotOfferedForANonUpgradableBuilding() throws {
        guard let installURL else { print("upgrade-availability: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL))
        guard let sim = model.simulation else { Issue.record("no simulation after load"); return }

        // A windtrap has no upgrade at any campaign level, so the Upgrade control must be hidden (upgradable
        // == false) — vs. merely disabled. (Skips if this scenario's player has no windtrap.)
        let player = UInt8(model.playerHouse.rawValue)
        guard let slot = sim.state.structures.firstIndex(where: {
            $0.o.flags.contains(.used)
                && $0.o.houseID == player
                && $0.o.type == UInt8(StructureType.windtrap.rawValue)
        }) else {
            print("upgrade-availability: no player windtrap in first scenario — skipped")
            return
        }
        let packed = sim.state.structures[slot].o.position.packed
        _ = model.rightClickOpensBuildingMenu(tileX: Int(packed % 64), tileY: Int(packed / 64), at: .zero)
        #expect(model.structureActions?.upgradable == false, "a windtrap is never upgradable → hide Upgrade")
    }
}
