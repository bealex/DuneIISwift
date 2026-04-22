import Foundation

extension Simulation {
    /// House-relation helpers. `HousePool` carries the mutable slot state;
    /// the `House` namespace holds pure functions the simulation needs
    /// without pulling in pool state.
    public enum House {
        /// `HOUSE_INVALID` sentinel from OpenDUNE `src/house.h:18`.
        public static let invalidID: UInt8 = 0xFF

        public static let harkonnen: UInt8 = 0
        public static let atreides: UInt8  = 1
        public static let ordos: UInt8     = 2
        public static let fremen: UInt8    = 3
        public static let sardaukar: UInt8 = 4
        public static let mercenary: UInt8 = 5

        /// `1 << houseID`. OpenDUNE uses the shifted value directly in
        /// `availableHouse` bitmasks (`src/house.h:FLAG_HOUSE_*`).
        public static func flag(for houseID: UInt8) -> UInt8 { 1 << houseID }

        /// `FLAG_HOUSE_ALL` — all six houses selected (bits 0..5).
        public static let flagAll: UInt8 = 0b0011_1111

        /// BARRACKS `availableHouse` — every house *except* Harkonnen.
        public static let flagBarracksHouses: UInt8 = 0b0011_1110

        /// WOR_TROOPER `availableHouse` — every house *except* Atreides.
        public static let flagWorHouses: UInt8 = 0b0011_1101

        /// Port of OpenDUNE `House_AreAllied` (`src/house.c:353`). When
        /// `playerHouseID` is nil, we degrade to "allied iff `a == b`",
        /// which is the conservative default for tests that haven't set
        /// up a player. Fremen are always allied to Atreides. All
        /// non-player houses are implicit allies of each other.
        /// Spending-cash lookup for HUD readouts. Returns `nil` for an
        /// out-of-range houseID or an unallocated slot — distinct from
        /// "house has 0 credits" (returns `0`). Note that
        /// `HousePool.free` leaves `isUsed == true` (matches OpenDUNE's
        /// `House_Free` quirk), so a freed house still answers its
        /// credits — see `Documentation/Insights/simulation-house-free-leaves-used.md`.
        public static func credits(for houseID: UInt8, in pool: HousePool) -> UInt16? {
            let idx = Int(houseID)
            guard idx >= 0, idx < HousePool.capacity else { return nil }
            let slot = pool.slots[idx]
            guard slot.isUsed else { return nil }
            return slot.credits
        }

        public static func areAllied(_ a: UInt8, _ b: UInt8, playerHouseID: UInt8? = nil) -> Bool {
            if a == invalidID || b == invalidID { return false }
            if a == b { return true }
            guard let player = playerHouseID else { return false }
            if a == fremen || b == fremen {
                return a == atreides || b == atreides
            }
            return a != player && b != player
        }
    }
}
