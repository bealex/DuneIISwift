import DuneIIContracts
import DuneIIWorld

/// The replaceable seam for the native map primitives ported from OpenDUNE `src/map.c`. Injected into
/// `Simulation` so the implementation can be swapped (see `UnitPrimitives`).
///
/// Only the position-validity check is here so far; the landscape/spice/fog primitives
/// (`Map_GetLandscapeType`, `Map_ChangeSpiceAmount`, `Map_UnveilTile`, …) are blocked on the
/// sprite/scenario init that derives the runtime tile-id bases from `ICON.MAP` (`Sprites_Init`,
/// `sprites.c:274`) — see `Documentation/Plan.v1.md` §9.
public protocol MapPrimitives: Sendable {
    /// `Map_IsValidPosition` (`map.c`): is `position` (a packed tile) inside the playable bounds for
    /// `mapScale`? (Out-of-map bits, then the per-scale `MapInfo` rectangle.)
    func isValidPosition(_ position: UInt16, mapScale: UInt8) -> Bool
}

public struct DefaultMapPrimitives: MapPrimitives {
    public init() {}

    public func isValidPosition(_ position: UInt16, mapScale: UInt8) -> Bool {
        if position & 0xC000 != 0 { return false }
        let x = UInt16(Tile32.packedX(position))
        let y = UInt16(Tile32.packedY(position))
        let info = MapInfo.scales[Int(mapScale)]
        return info.minX <= x && x < info.minX + info.sizeX
            && info.minY <= y && y < info.minY + info.sizeY
    }
}
