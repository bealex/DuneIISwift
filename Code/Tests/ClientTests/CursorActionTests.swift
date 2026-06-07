import AppKit
import DuneIIContracts
import DuneIISimulation
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIIClient

/// `GameModel.unitOrderIsAttack` resolves the would-be right-click order (the map cursor's meaning) for the
/// current selection: `nil` with nothing selected, `false` (move) over empty / own / **fogged** tiles, and
/// `true` (attack) only over a revealed enemy. This is the testable core of the context cursor; the actual
/// `NSCursor` swap in `GameScene` is macOS presentation. Skips without the install.
@MainActor
struct CursorActionTests {
    private var installURL: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }  // Code/Tests/ClientTests/x.swift → repo
        let url = root.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test func resolvesMoveVsAttackAndAlwaysMoveOverFog() throws {
        guard let installURL else { print("cursor-action: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL))  // loads the first scenario in init
        guard let sim = model.simulation else { Issue.record("no simulation after load"); return }

        // Nothing selected ⇒ no order ⇒ the plain pointer.
        #expect(model.unitOrderIsAttack(tileX: 32, tileY: 32) == nil)

        // Select a player combat (non-harvester) ground unit by left-clicking its tile.
        let player = UInt8(model.playerHouse.rawValue)
        guard let slot = sim.state.units.firstIndex(where: {
            $0.o.flags.contains(.used)
                && $0.o.houseID == player
                && $0.o.type != UInt8(UnitType.harvester.rawValue)
                && $0.o.type != UInt8(UnitType.carryall.rawValue)
        }) else {
            print("cursor-action: no selectable player unit in first scenario — skipped")
            return
        }
        let packed = sim.state.units[slot].o.position.packed
        let ux = Int(packed % 64), uy = Int(packed / 64)
        model.leftClickTile(ux, uy)
        #expect(model.selectedUnitCount >= 1, "left-click should select the player unit")

        // Over the unit's own (revealed) tile there is no enemy ⇒ move.
        #expect(model.unitOrderIsAttack(tileX: ux, tileY: uy) == false)

        // A tile under fog always resolves to move — you can't target what you haven't revealed.
        if let fogged = sim.state.map.firstIndex(where: { !$0.isUnveiled }) {
            #expect(
                model.unitOrderIsAttack(tileX: fogged % 64, tileY: fogged / 64) == false,
                "a fogged tile must resolve to move, never attack"
            )
        } else {
            print("cursor-action: whole map revealed — fog assertion skipped")
        }
    }
}
