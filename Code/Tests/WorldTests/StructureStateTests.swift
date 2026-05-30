import Testing
import DuneIIContracts
@testable import DuneIIWorld

/// `Structure_SetRepairingState` / `Structure_SetUpgradingState` (`structure.c:1735` / `:1691`) — the
/// production-trigger setters that flip the flags the `tickStructure` repair/upgrade branches act on.
/// (The setters are `mutating`, so each call is made before the `#expect` — the macro would otherwise
/// capture the state as immutable.)
@Suite("Structure repair/upgrade state setters")
struct StructureStateTests {
    private func structure(_ type: StructureType = .windtrap, hp: UInt16? = nil) -> (GameState, Int) {
        var s = GameState()
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        s.structures[slot].o.hitpoints = hp ?? StructureInfo[type].o.hitpoints
        return (s, slot)
    }

    // MARK: - Repairing

    @Test("start repairing a damaged structure sets .repairing + .onHold")
    func startRepair() {
        var (s, slot) = structure(hp: 50)
        let acted = s.structureSetRepairingState(slot, state: 1)
        #expect(acted)
        #expect(s.structures[slot].o.flags.contains(.repairing))
        #expect(s.structures[slot].o.flags.contains(.onHold))
    }

    @Test("starting repair on a full-HP structure is a no-op")
    func repairFullHP() {
        var (s, slot) = structure()   // full HP
        let acted = s.structureSetRepairingState(slot, state: 1)
        #expect(!acted)
        #expect(!s.structures[slot].o.flags.contains(.repairing))
    }

    @Test("stopping repair clears .repairing + .onHold")
    func stopRepair() {
        var (s, slot) = structure(hp: 50)
        _ = s.structureSetRepairingState(slot, state: 1)
        let acted = s.structureSetRepairingState(slot, state: 0)
        #expect(acted)
        #expect(!s.structures[slot].o.flags.contains(.repairing))
        #expect(!s.structures[slot].o.flags.contains(.onHold))
    }

    @Test("toggle (-1) flips the repair state")
    func toggleRepair() {
        var (s, slot) = structure(hp: 50)
        _ = s.structureSetRepairingState(slot, state: -1)
        #expect(s.structures[slot].o.flags.contains(.repairing))
        _ = s.structureSetRepairingState(slot, state: -1)
        #expect(!s.structures[slot].o.flags.contains(.repairing))
    }

    @Test("a non-allocated structure can't start repairing (state forced to 0)")
    func repairNotAllocated() {
        var (s, slot) = structure(hp: 50)
        s.structures[slot].o.flags.remove(.allocated)
        let acted = s.structureSetRepairingState(slot, state: 1)
        #expect(!acted)
        #expect(!s.structures[slot].o.flags.contains(.repairing))
    }

    // MARK: - Upgrading

    @Test("start upgrading (with time left) sets .upgrading + .onHold and clears .repairing")
    func startUpgrade() {
        var (s, slot) = structure(hp: 50)
        s.structures[slot].o.flags.insert(.repairing)   // a repairing structure...
        s.structures[slot].upgradeTimeLeft = 30
        let acted = s.structureSetUpgradingState(slot, state: 1)
        #expect(acted)
        #expect(s.structures[slot].o.flags.contains(.upgrading))
        #expect(s.structures[slot].o.flags.contains(.onHold))
        #expect(!s.structures[slot].o.flags.contains(.repairing))   // ...upgrading supersedes repairing
    }

    @Test("starting upgrade with no time left is a no-op")
    func upgradeNoTimeLeft() {
        var (s, slot) = structure()
        s.structures[slot].upgradeTimeLeft = 0
        let acted = s.structureSetUpgradingState(slot, state: 1)
        #expect(!acted)
        #expect(!s.structures[slot].o.flags.contains(.upgrading))
    }

    @Test("stopping upgrade clears .upgrading + .onHold")
    func stopUpgrade() {
        var (s, slot) = structure()
        s.structures[slot].upgradeTimeLeft = 30
        _ = s.structureSetUpgradingState(slot, state: 1)
        let acted = s.structureSetUpgradingState(slot, state: 0)
        #expect(acted)
        #expect(!s.structures[slot].o.flags.contains(.upgrading))
        #expect(!s.structures[slot].o.flags.contains(.onHold))
    }
}
