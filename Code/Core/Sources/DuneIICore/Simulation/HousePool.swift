import Foundation

extension Simulation {
    public struct HouseSlot: Sendable, Equatable {
        public var isUsed: Bool
        public var index: UInt8
        /// Head of the chain of units waiting for the next frigate.
        /// `0xFFFF` when no order is pending (mirrors OpenDUNE's
        /// `UNIT_INDEX_INVALID`). Each linked unit stores the next in
        /// `UnitSlot.linkedID`, chain-terminated by `0xFF`.
        public var starportLinkedID: UInt16
        /// Countdown in `tickStarport` cadence units (OpenDUNE fires
        /// this every 180 game ticks). On order commit, re-seeded to
        /// `HouseInfo.starportDeliveryTime` (= 10 for houses 0..2).
        /// When it reaches 0 with a live `starportLinkedID`, a frigate
        /// is spawned and the linked-ID chain moves onto it.
        public var starportTimeLeft: UInt16
        /// Spending cash on hand. Drained per tick by BUSY yards
        /// (slice 6b); refunded on cancel. Seeded from
        /// `Scenario.HouseLayout.credits` or the save's `PLYR` record.
        /// Slice 6a.
        public var credits: UInt16
        /// Cap on storable credits — sum of refinery + silo capacities.
        /// Stored so save round-trips survive; live refreshes come
        /// with the HUD / economy slice.
        public var creditsStorage: UInt16
        /// Scenario win-condition target (harvester revenue needed).
        /// Pure read — never written by the engine.
        public var creditsQuota: UInt16
        /// Sum of windtrap power output for every active structure this
        /// house owns. `House_CalculatePowerAndCredit` recomputes it on
        /// each `tickHouse`; for now we only surface the save-loaded
        /// value so the `tickPowerMaintenance` drain formula has real
        /// numbers to read.
        public var powerProduction: UInt16
        /// Sum of power consumption across active structures this house
        /// owns. Read by `tickPowerMaintenance` (`src/house.c:270..273`):
        /// every 10 800 ticks the house pays `(powerUsage / 32) + 1`
        /// credits, capped at its current balance. With Atreides at
        /// `powerUsage=30` in SAVE007 this costs exactly 1 credit
        /// starting at tick 70 — which is precisely what OpenDUNE's
        /// `max(g_timerGame + 70, saved)` load-time seed produces.
        public var powerUsage: UInt16
        /// Live count of units owned by this house. Mirrors OpenDUNE's
        /// `h->unitCount` (`src/house.h:80`): `Unit_Allocate` increments,
        /// `Unit_Free` decrements, `Unit_Recount` rebuilds from the
        /// unit pool. Used by `Unit_Allocate`'s `h->unitCount >=
        /// h->unitCountMax` cap gate (`src/pool/unit.c:115`) and by
        /// the parity golden's compareHouse diff.
        public var unitCount: UInt16
        /// Cap on simultaneous owned units. Scenario-seeded and
        /// normally static through a mission (upgrades can raise it
        /// but we haven't ported that path yet). Enforces
        /// `Unit_Allocate`'s return-NULL on overflow.
        public var unitCountMax: UInt16
        /// Number of harvesters queued for deferred delivery. Set to
        /// 1 by `Unit_CreateWrapper`/`Unit_Create` when a fresh
        /// harvester allocation fails because the house is already at
        /// `unitCountMax` (`src/unit.c:1801..1818`); decremented when
        /// a carryall actually delivers the queued harvester. Only
        /// meaningful when the delayed-delivery path fires.
        public var harvestersIncoming: UInt16

        public init(
            isUsed: Bool = false,
            index: UInt8 = 0,
            starportLinkedID: UInt16 = 0,
            starportTimeLeft: UInt16 = 0,
            credits: UInt16 = 0,
            creditsStorage: UInt16 = 0,
            creditsQuota: UInt16 = 0,
            powerProduction: UInt16 = 0,
            powerUsage: UInt16 = 0,
            unitCount: UInt16 = 0,
            unitCountMax: UInt16 = 0,
            harvestersIncoming: UInt16 = 0
        ) {
            self.isUsed = isUsed
            self.index = index
            self.starportLinkedID = starportLinkedID
            self.starportTimeLeft = starportTimeLeft
            self.credits = credits
            self.creditsStorage = creditsStorage
            self.creditsQuota = creditsQuota
            self.powerProduction = powerProduction
            self.powerUsage = powerUsage
            self.unitCount = unitCount
            self.unitCountMax = unitCountMax
            self.harvestersIncoming = harvestersIncoming
        }
    }

    public struct HousePool: Sendable, Equatable {
        public static let capacity = 6
        public static let invalidIndex: UInt16 = 0xFFFF

        public private(set) var slots: [HouseSlot]
        public private(set) var findArray: [Int]

        public init() {
            self.slots = Array(repeating: HouseSlot(), count: Self.capacity)
            self.findArray = []
        }

        public subscript(index: Int) -> HouseSlot {
            get { slots[index] }
            set { slots[index] = newValue }
        }

        @discardableResult
        public mutating func allocate(at index: Int) -> Int? {
            guard index >= 0, index < Self.capacity else { return nil }
            guard !slots[index].isUsed else { return nil }
            slots[index] = HouseSlot(
                isUsed: true,
                index: UInt8(index),
                starportLinkedID: 0xFFFF
            )
            findArray.append(index)
            return index
        }

        /// Removes the house from `findArray` but **leaves `slots[i].isUsed == true`**,
        /// mirroring OpenDUNE's `House_Free` quirk. See
        /// `Documentation/Insights/simulation-house-free-leaves-used.md`.
        public mutating func free(at index: Int) {
            guard index >= 0, index < Self.capacity, slots[index].isUsed else { return }
            if let position = findArray.firstIndex(of: index) {
                findArray.remove(at: position)
            }
        }

        /// Port of OpenDUNE's `Unit_Recount` side effect
        /// (`src/pool/unit.c:75..97`): zeroes every house's
        /// `unitCount`, then walks the unit pool and bumps the owning
        /// house's counter for each `isUsed` slot. OpenDUNE runs
        /// this once after `SaveGame_LoadFile` and relies on
        /// incremental `Unit_Allocate`/`Unit_Free` maintenance
        /// otherwise. Swift currently runs it also at end-of-tick for
        /// the same effect (cheap — 6 houses × 102 units), pending a
        /// full migration of every `UnitPool.allocate/.free` call
        /// site to an inline-bump helper.
        public mutating func recount(from units: UnitPool) {
            for i in 0..<Self.capacity {
                if slots[i].isUsed { slots[i].unitCount = 0 }
            }
            for slot in units.slots where slot.isUsed {
                let h = Int(slot.houseID)
                guard h >= 0, h < Self.capacity, slots[h].isUsed else { continue }
                slots[h].unitCount &+= 1
            }
        }
    }
}
