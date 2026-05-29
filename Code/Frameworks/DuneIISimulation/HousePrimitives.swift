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
        if houseID1 == Pool.houseInvalid || houseID2 == Pool.houseInvalid { return false }
        if houseID1 == houseID2 { return true }

        let fremen = UInt8(HouseID.fremen.rawValue)
        let atreides = UInt8(HouseID.atreides.rawValue)
        if houseID1 == fremen || houseID2 == fremen {
            return houseID1 == atreides || houseID2 == atreides
        }
        return houseID1 != playerHouseID && houseID2 != playerHouseID
    }
}
