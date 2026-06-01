import Testing
import DuneIIContracts
@testable import DuneIIWorld
@testable import DuneIISimulation

/// Starport CHOAM ordering — the per-unit body of `Structure_BuildObject`'s `FACTORY_BUY` loop
/// (`structure.c:1577`), lifted out of the GUI factory window. An order creates the unit off-map, chains it
/// onto the house's `starportLinkedID` delivery list, arms the delivery timer, and decrements the stock.
@Suite("Starport CHOAM order")
struct StarportOrderTests {
    private let info = ScriptInfo(program: [UInt16](repeating: 0, count: 64), offsets: (0 ..< 30).map { UInt16($0) })

    private func base() -> (GameState, UnitCombat, Int) {
        var s = GameState(); s.playerHouseID = 0
        _ = s.houseAllocate(index: 0); s.houses[0].unitCountMax = 100
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.starport.rawValue))!
        s.structures[slot].o.houseID = 0
        s.structures[slot].o.hitpoints = StructureInfo[.starport].o.hitpoints
        s.structures[slot].state = .idle
        return (s, UnitCombat(movement: UnitMovement(scriptInfo: info)), slot)
    }

    private let trike = UInt16(UnitType.trike.rawValue)
    private let quad = UInt16(UnitType.quad.rawValue)

    @Test("an in-stock order chains the unit, arms the timer, and decrements stock")
    func ordersOne() {
        var (s, combat, sp) = base()
        s.starportAvailable[Int(trike)] = 3
        #expect(combat.structureStarportOrder(slot: sp, objectType: trike, in: &s))
        let head = Int(s.houses[0].starportLinkedID)
        #expect(s.units[head].o.type == UInt8(trike))
        #expect(s.units[head].o.linkedID == 0xFF)   // first order links to the empty list (0xFFFF & 0xFF)
        #expect(s.houses[0].starportTimeLeft == HouseInfo[.harkonnen].starportDeliveryTime)
        #expect(s.starportAvailable[Int(trike)] == 2)
    }

    @Test("a second order chains in front of the first (newest is the list head)")
    func ordersChain() {
        var (s, combat, sp) = base()
        s.starportAvailable[Int(trike)] = 3; s.starportAvailable[Int(quad)] = 3
        _ = combat.structureStarportOrder(slot: sp, objectType: trike, in: &s)
        let first = Int(s.houses[0].starportLinkedID)
        _ = combat.structureStarportOrder(slot: sp, objectType: quad, in: &s)
        let second = Int(s.houses[0].starportLinkedID)
        #expect(second != first)
        #expect(Int(s.units[second].o.linkedID) == first)   // newest → previous head
    }

    @Test("ordering the last in stock marks the type sold out (−1)")
    func soldOut() {
        var (s, combat, sp) = base()
        s.starportAvailable[Int(trike)] = 1
        #expect(combat.structureStarportOrder(slot: sp, objectType: trike, in: &s))
        #expect(s.starportAvailable[Int(trike)] == -1)
    }

    @Test("an out-of-stock order is refused and the list stays empty")
    func outOfStock() {
        var (s, combat, sp) = base()
        s.starportAvailable[Int(trike)] = 0
        #expect(!combat.structureStarportOrder(slot: sp, objectType: trike, in: &s))
        #expect(s.houses[0].starportLinkedID == Pool.unitIndexInvalid)
    }

    @Test("a priced order charges the house, and refunds when the pool is full")
    func chargesPrice() {
        var (s, combat, sp) = base()
        s.starportAvailable[Int(trike)] = 1
        s.houses[0].credits = 500
        #expect(combat.structureStarportOrder(slot: sp, objectType: trike, price: 200, in: &s))
        #expect(s.houses[0].credits == 300)   // charged 200

        // Fill the trike pool so the next allocate fails, and confirm the charge is refunded.
        var s2 = s
        s2.starportAvailable[Int(trike)] = 5
        s2.houses[0].credits = 500
        for i in UnitInfo[.trike].indexStart ... UnitInfo[.trike].indexEnd {
            s2.units[Int(i)].o.flags.insert([.used, .allocated])
        }
        #expect(!combat.structureStarportOrder(slot: sp, objectType: trike, price: 200, in: &s2))
        #expect(s2.houses[0].credits == 500)   // refunded
    }

    @Test("ordering from a non-starport factory is refused")
    func notStarport() {
        var (s, combat, _) = base()
        let cy = s.structureAllocate(index: Pool.structureIndexInvalid,
                                     type: UInt8(StructureType.constructionYard.rawValue))!
        s.structures[cy].o.houseID = 0
        s.starportAvailable[Int(trike)] = 3
        #expect(!combat.structureStarportOrder(slot: cy, objectType: trike, in: &s))
    }
}
