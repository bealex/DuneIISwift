import Testing
import DuneIIContracts
@testable import DuneIIWorld

/// `House_CalculatePowerAndCredit` (`house.c:470`) — a house's power production/usage + credit storage are
/// summed from its structures: consumers add `powerUsage`, power plants produce `-powerUsage` (scaled by
/// hitpoints when damaged), and storage adds `creditsStorage`. Expected values are read back from the
/// (golden-verified) stat tables so the test tracks the tables, not hand-copied numbers.
@Suite("House power + credits")
struct HouseEconomyTests {
    private func place(_ s: inout GameState, _ type: StructureType, house: UInt8, hp: UInt16) {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(type.rawValue))!
        s.structures[slot].o.houseID = house
        s.structures[slot].o.hitpoints = hp
    }

    @Test("sums consumers, producers, and storage over the house's structures")
    func calculate() {
        var s = GameState()
        _ = s.houseAllocate(index: 0)
        place(&s, .windtrap, house: 0, hp: StructureInfo[.windtrap].o.hitpoints)   // producer (powerUsage -100)
        place(&s, .refinery, house: 0, hp: StructureInfo[.refinery].o.hitpoints)   // consumer + 1005 storage
        // A structure of another house must not count toward house 0.
        place(&s, .windtrap, house: 1, hp: StructureInfo[.windtrap].o.hitpoints)

        s.houseCalculatePowerAndCredit(0)
        #expect(s.houses[0].powerProduction == UInt16(-Int(StructureInfo[.windtrap].powerUsage)))   // 100
        #expect(s.houses[0].powerUsage == UInt16(StructureInfo[.refinery].powerUsage))              // 30
        #expect(s.houses[0].creditsStorage == StructureInfo[.refinery].creditsStorage)              // 1005
    }

    @Test("a damaged power plant produces proportionally less (1.07: ≤ half HP → half)")
    func damagedPlant() {
        let full = StructureInfo[.windtrap].o.hitpoints
        let capacity = UInt16(-Int(StructureInfo[.windtrap].powerUsage))   // 100

        // ≤ half HP → exactly half output.
        var s = GameState(); _ = s.houseAllocate(index: 0)
        place(&s, .windtrap, house: 0, hp: full / 2)
        s.houseCalculatePowerAndCredit(0)
        #expect(s.houses[0].powerProduction == capacity / 2)

        // Above half (¾ HP) → scaled by the hitpoint fraction.
        var s2 = GameState(); _ = s2.houseAllocate(index: 0)
        let hp = full * 3 / 4
        place(&s2, .windtrap, house: 0, hp: hp)
        s2.houseCalculatePowerAndCredit(0)
        #expect(s2.houses[0].powerProduction == UInt16(UInt32(capacity) * UInt32(hp) / UInt32(full)))
    }

    @Test("recompute is idempotent: it resets the accumulators each call")
    func idempotent() {
        var s = GameState()
        _ = s.houseAllocate(index: 0)
        place(&s, .windtrap, house: 0, hp: StructureInfo[.windtrap].o.hitpoints)
        s.houseCalculatePowerAndCredit(0)
        let first = s.houses[0].powerProduction
        s.houseCalculatePowerAndCredit(0)   // a second call must not double-count
        #expect(s.houses[0].powerProduction == first)
    }
}
