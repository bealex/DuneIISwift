import AppKit
import DuneIIContracts
import DuneIIInput
import DuneIISimulation
import DuneIIWorld
import Foundation
import Testing

@testable import DuneIIClient

/// `GameModel` control groups + formation capture — the macOS Cmd+digit save / digit recall and the
/// relative-arrangement preservation that drives multi-unit moves. Pure model logic (the keyboard wiring in
/// `GameScene` is macOS presentation); skips without the original install.
@MainActor
struct ControlGroupFormationTests {
    private var installURL: URL? {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }  // Code/Tests/ClientTests/x.swift → repo
        let url = root.appendingPathComponent("Repositories/patched_107_unofficial", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// All slots of the most-numerous player-owned, on-map, normal unit type (a group of ≥2 to exercise),
    /// or `nil` if no such pair exists in the first scenario.
    private func dominantPlayerGroup(_ model: GameModel) -> (type: UInt8, slots: [Int])? {
        guard let state = model.simulation?.state else { return nil }

        let ph = UInt8(model.playerHouse.rawValue)
        var byType: [UInt8: [Int]] = [:]
        for i in state.units.indices where state.units[i].o.flags.contains(.used) {
            let u = state.units[i]
            guard
                u.o.houseID == ph,
                !u.o.flags.contains(.isNotOnMap),
                let ut = UnitType(rawValue: Int(u.o.type)),
                UnitInfo[ut].flags.contains(.isNormalUnit)
            else { continue }

            byType[u.o.type, default: []].append(i)
        }
        guard let best = byType.max(by: { $0.value.count < $1.value.count }), best.value.count >= 2 else {
            return nil
        }
        return (best.key, best.value)
    }

    @Test func formationOffsetsAreLeaderRelative() throws {
        guard let installURL else { print("formation: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL))
        guard let state = model.simulation?.state, let group = dominantPlayerGroup(model) else {
            print("formation: no ≥2-unit player group in first scenario — skipped")
            return
        }

        // The leader is the first slot; its own offset is (0,0) so a move sends it to the exact clicked tile.
        let leader = group.slots[0], other = group.slots[1]
        let offsets = model.formationOffsets(for: group.slots, state: state)
        #expect(offsets.count == group.slots.count, "one offset per unit")
        #expect(offsets[leader] == TileOffset(dx: 0, dy: 0), "the leader anchors the formation")
        // Each non-leader offset is its tile minus the leader's tile.
        let lx = Int(state.units[leader].o.position.packed) % 64, ly = Int(state.units[leader].o.position.packed) / 64
        let ox = Int(state.units[other].o.position.packed) % 64, oy = Int(state.units[other].o.position.packed) / 64
        #expect(offsets[other] == TileOffset(dx: ox - lx, dy: oy - ly))

        // A single-unit group has no meaningful formation.
        #expect(model.formationOffsets(for: [ leader ], state: state).isEmpty)
    }

    @Test func clickedUnitBecomesLeader() throws {
        guard let installURL else { print("leader: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL))
        guard let group = dominantPlayerGroup(model), group.slots.count >= 2 else {
            print("leader: no ≥2-unit player group — skipped")
            return
        }

        // Triple-click on a *non-first* member: it must become the selection's leader regardless of slot order.
        let pick = group.slots[1]
        let packed = model.simulation!.state.units[pick].o.position.packed
        model.tripleClickSelectAllSameType(tileX: Int(packed) % 64, tileY: Int(packed) / 64)
        #expect(model.selectedUnitCount >= 2)
        #expect(model.leaderSlot == pick, "the clicked unit leads the group")
    }

    @Test func saveAndRecallControlGroup() throws {
        guard let installURL else { print("control-group: no install — skipped"); return }

        NSApplication.shared.setActivationPolicy(.accessory)
        let model = GameModel(assets: AssetStore(installURL: installURL))
        guard let group = dominantPlayerGroup(model) else {
            print("control-group: no ≥2-unit player group in first scenario — skipped")
            return
        }

        // Select the whole same-type group via a triple-click on one member, then store it under digit 1.
        let lead = group.slots[0]
        let packed = model.simulation!.state.units[lead].o.position.packed
        model.tripleClickSelectAllSameType(tileX: Int(packed) % 64, tileY: Int(packed) / 64)
        let selected = model.selectedUnitCount
        #expect(selected >= 2, "triple-click should select the same-type group")
        model.saveControlGroup(1)

        // Clear the selection, then recall — the full group comes back.
        model.deselect()
        #expect(model.selectedUnitCount == 0)
        model.recallControlGroup(1)
        #expect(model.selectedUnitCount == selected, "recall restores the saved group")

        // Recall preserves the formation captured at save time (offset per recalled unit).
        #expect(!model.formationOffsets(for: group.slots, state: model.simulation!.state).isEmpty)

        // An empty digit is a no-op (leaves the current selection alone).
        model.recallControlGroup(9)
        #expect(model.selectedUnitCount == selected)

        // Saving with nothing selected doesn't overwrite an existing group.
        model.deselect()
        model.saveControlGroup(1)
        model.recallControlGroup(1)
        #expect(model.selectedUnitCount == selected, "an empty selection must not clobber a saved group")
    }
}
