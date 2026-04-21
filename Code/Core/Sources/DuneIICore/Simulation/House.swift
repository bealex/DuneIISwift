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
