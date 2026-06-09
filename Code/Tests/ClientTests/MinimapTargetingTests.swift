import AppKit
import DuneIIContracts
import DuneIISimulation
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIIClient

/// The minimap doubles as a navigator and a target picker. `GameModel.minimapPrimaryClick` recentres the map
/// when nothing is being targeted, but confirms an **armed** unit order (Move/Attack/Harvest) at the clicked
/// tile instead — so a primary click on the minimap can move/attack/harvest, not just pan. Skips without the
/// install (it drives the real loaded scenario, like `CursorActionTests`).
@MainActor
struct MinimapTargetingTests {
    private var installURL: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }  // Code/Tests/ClientTests/x.swift → repo
        let url = root.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test func primaryClickRecentresWhenNotTargeting() throws {
        guard let installURL else { print("minimap-target: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL))

        #expect(!model.isOrderArmed, "no selection ⇒ not armed")
        // Two far-apart primary clicks move the camera centre to two different (clamped) points ⇒ it recentred.
        model.minimapPrimaryClick(tileX: 0, tileY: 0, worldX: 0, worldY: 0)
        let a = CGPoint(x: model.viewport.centerX, y: model.viewport.centerY)
        model.minimapPrimaryClick(tileX: 63, tileY: 63, worldX: Viewport.worldSize, worldY: Viewport.worldSize)
        let b = CGPoint(x: model.viewport.centerX, y: model.viewport.centerY)
        #expect(a != b, "an un-armed primary click should recentre the map (centres differ: \(a) vs \(b))")
    }

    @Test func primaryClickConfirmsAnArmedOrderInsteadOfRecentring() throws {
        guard let installURL else { print("minimap-target: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL))
        guard let sim = model.simulation else { Issue.record("no simulation after load"); return }

        // Select a player combat unit (the same filter CursorActionTests uses).
        let player = UInt8(model.playerHouse.rawValue)
        guard
            let slot = sim.state.units.firstIndex(where: {
                $0.o.flags.contains(.used)
                    && $0.o.houseID == player
                    && $0.o.type != UInt8(UnitType.harvester.rawValue)
                    && $0.o.type != UInt8(UnitType.carryall.rawValue)
            })
        else {
            print("minimap-target: no selectable player unit — skipped")
            return
        }

        let packed = sim.state.units[slot].o.position.packed
        model.leftClickTile(Int(packed % 64), Int(packed / 64))
        guard model.selectedUnitCount >= 1 else { Issue.record("unit not selected"); return }

        // Arm a Move order; the model is now targeting.
        model.issueAction(.move)
        guard model.isOrderArmed else { print("minimap-target: unit can't arm Move — skipped"); return }

        // A primary minimap click now confirms the order at the tile (and must NOT recentre the camera).
        let before = CGPoint(x: model.viewport.centerX, y: model.viewport.centerY)
        model.minimapPrimaryClick(tileX: 10, tileY: 10, worldX: 160, worldY: 160)
        #expect(!model.isOrderArmed, "the armed order should be consumed by the minimap click")
        #expect(
            model.viewport.centerX == before.x && model.viewport.centerY == before.y,
            "confirming an order must not recentre the map"
        )
    }
}
