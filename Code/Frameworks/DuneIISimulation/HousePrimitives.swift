import DuneIIContracts
import DuneIIWorld

/// The replaceable seam for the native house primitives ported from OpenDUNE `src/house.c`. Injected
/// into `Simulation` so the implementation can be swapped (see `UnitPrimitives`).
public protocol HousePrimitives: Sendable {
    /// `House_AreAllied` (`house.c`): are two houses allied? Same house = allied; Fremen ally only with
    /// Atreides; otherwise any two non-player houses are allied (the AI ganging up on the player).
    /// `0xFF` (HOUSE_INVALID) is never allied.
    func areAllied(_ houseID1: UInt8, _ houseID2: UInt8, playerHouseID: UInt8) -> Bool
}

public struct DefaultHousePrimitives: HousePrimitives {
    public init() {}

    public func areAllied(_ houseID1: UInt8, _ houseID2: UInt8, playerHouseID: UInt8) -> Bool {
        House.areAllied(houseID1, houseID2, playerHouseID: playerHouseID)
    }
}
