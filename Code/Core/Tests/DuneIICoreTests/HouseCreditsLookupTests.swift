import Foundation
import Testing
@testable import DuneIICore

/// Tests for `Simulation.House.credits(for:in:)` — the pure-sim HUD
/// lookup helper that the credits label reads each tick.
///
/// `nil` distinguishes "no such house" (out-of-range or unallocated
/// slot) from "house has zero credits" — the HUD shows "—" for the
/// former and "0" for the latter.
@Suite("Simulation.House.credits(for:in:) — HUD credits lookup")
struct HouseCreditsLookupTests {

    @Test("allocated house with non-zero credits returns the value")
    func nonZeroCredits() {
        var pool = Simulation.HousePool()
        _ = pool.allocate(at: Int(Simulation.House.atreides))
        var slot = pool[Int(Simulation.House.atreides)]
        slot.credits = 1000
        pool[Int(Simulation.House.atreides)] = slot

        let value = Simulation.House.credits(for: Simulation.House.atreides, in: pool)
        #expect(value == 1000)
    }

    @Test("allocated house with zero credits returns 0, not nil")
    func zeroCreditsAllocated() {
        var pool = Simulation.HousePool()
        _ = pool.allocate(at: Int(Simulation.House.harkonnen))
        // credits defaults to 0 on allocate.
        let value = Simulation.House.credits(for: Simulation.House.harkonnen, in: pool)
        #expect(value == 0)
    }

    @Test("unallocated slot returns nil")
    func unallocatedReturnsNil() {
        let pool = Simulation.HousePool()
        let value = Simulation.House.credits(for: Simulation.House.atreides, in: pool)
        #expect(value == nil)
    }

    @Test("freed slot still returns the value (HousePool.free leaves isUsed set)")
    func freedSlotStillReadable() {
        // Mirrors OpenDUNE's House_Free quirk — `isUsed` stays true even
        // after `free`. The HUD lookup follows that semantics: a freed
        // house still answers its credits. This guards against a future
        // refactor that "fixes" the quirk and silently breaks the HUD.
        var pool = Simulation.HousePool()
        _ = pool.allocate(at: Int(Simulation.House.atreides))
        var slot = pool[Int(Simulation.House.atreides)]
        slot.credits = 250
        pool[Int(Simulation.House.atreides)] = slot
        pool.free(at: Int(Simulation.House.atreides))

        let value = Simulation.House.credits(for: Simulation.House.atreides, in: pool)
        #expect(value == 250)
    }

    @Test("out-of-range houseID returns nil")
    func outOfRangeReturnsNil() {
        let pool = Simulation.HousePool()
        #expect(Simulation.House.credits(for: 6, in: pool) == nil)
        #expect(Simulation.House.credits(for: 0xFF, in: pool) == nil)
    }
}
