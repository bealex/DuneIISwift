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
