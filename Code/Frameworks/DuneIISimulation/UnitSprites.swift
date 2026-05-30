import DuneIIContracts
import DuneIIWorld

/// One drawable sprite layer of a unit. Aliased to the Contracts `SpriteLayer` (the canonical seam
/// type) so a unit's resolved layers cross the `sim → render` boundary without conversion; `spriteIndex`
/// is the global value OpenDUNE's `viewport.c` computes.
public typealias UnitSpriteLayer = SpriteLayer

/// The body (+ optional turret) sprite layers for a unit.
public struct UnitSpriteInfo: Equatable, Sendable {
    public let body: UnitSpriteLayer
    public let turret: UnitSpriteLayer?
}

/// Resolves the sprite layers to draw for a unit — a port of the per-unit drawing in OpenDUNE's
/// `GUI_Widget_Viewport_Draw` (`src/gui/viewport.c`): the body sprite (`groundSpriteID` + an
/// orientation-dependent frame offset per `displayMode`) and, for any unit with a `turretSpriteID`,
/// the turret (`turretSpriteID` + offset, oriented by `orientation[hasTurret ? 1 : 0]`, with a
/// per-type pixel offset). The viewer maps the global index to an SHP frame via the load-order bases.
public enum UnitSprites {
    /// `values_32A4` — UNIT/ROCKET directional (frames N,NE,E,SE,S; W half = E half mirrored).
    static let directional: [(offset: Int, flip: Bool)] =
        [(0, false), (1, false), (2, false), (3, false), (4, false), (3, true), (2, true), (1, true)]
    /// `values_32C4` — infantry (3 directions N,E,S).
    static let infantry: [(offset: Int, flip: Bool)] =
        [(0, false), (1, false), (1, false), (1, false), (2, false), (1, true), (1, true), (1, true)]
    /// `values_334A` — INFANTRY_3 animation sub-frame for `spriteOffset & 3`.
    static let infantry3Sub = [0, 1, 0, 2]
    /// `values_336E` — siege-tank turret pixel offset per orientation.
    static let siegeTurretOffset: [(Int, Int)] =
        [(0, -5), (0, -5), (2, -3), (2, -1), (-1, -3), (-2, -1), (-2, -3), (-1, -5)]
    /// `values_338E` — devastator turret pixel offset per orientation.
    static let devastatorTurretOffset: [(Int, Int)] =
        [(0, -4), (-1, -3), (2, -4), (0, -3), (-1, -3), (0, -3), (-2, -4), (1, -3)]

    public static func info(for unit: Unit) -> UnitSpriteInfo? {
        guard let type = UnitType(rawValue: Int(unit.o.type)) else { return nil }
        let info = UnitInfo[type]

        let bodyO8 = Int(Orientation.to8(UInt8(bitPattern: unit.orientation[0].current)))
        var bodyIndex = Int(info.groundSpriteID)
        var bodyFlip = false
        switch info.displayMode {
            case .unit, .rocket:
                let (offset, flip) = directional[bodyO8]
                bodyIndex += offset; bodyFlip = flip
            case .infantry3Frames:
                let (dir, flip) = infantry[bodyO8]
                bodyIndex += dir * 3 + infantry3Sub[Int(unit.spriteOffset) & 3]; bodyFlip = flip
            case .infantry4Frames:
                let (dir, flip) = infantry[bodyO8]
                bodyIndex += dir * 4 + (Int(unit.spriteOffset) & 3); bodyFlip = flip
            case .singleFrame, .ornithopter:
                break
        }
        let body = UnitSpriteLayer(spriteIndex: bodyIndex, flipped: bodyFlip, offsetX: 0, offsetY: 0)

        var turret: UnitSpriteLayer?
        if info.turretSpriteID != 0xFFFF {
            let slot = info.o.flags.contains(.hasTurret) ? 1 : 0
            let turretO8 = Int(Orientation.to8(UInt8(bitPattern: unit.orientation[slot].current)))
            let (offset, flip) = directional[turretO8]
            let (dx, dy) = turretOffset(info.turretSpriteID, turretO8)
            turret = UnitSpriteLayer(spriteIndex: Int(info.turretSpriteID) + offset, flipped: flip, offsetX: dx, offsetY: dy)
        }
        return UnitSpriteInfo(body: body, turret: turret)
    }

    /// The per-type turret pixel offset (`viewport.c`'s switch on `turretSpriteID`).
    static func turretOffset(_ turretSpriteID: UInt16, _ orientation: Int) -> (Int, Int) {
        switch turretSpriteID {
            case 141: return (0, -2)                          // sonic tank   (0x8D)
            case 146: return (0, -3)                          // launcher / deviator (0x92)
            case 126: return siegeTurretOffset[orientation]   // siege tank   (0x7E)
            case 136: return devastatorTurretOffset[orientation] // devastator (0x88)
            default:  return (0, 0)                           // combat tank, …
        }
    }
}
