import DuneIIContracts
import DuneIIWorld

/// One drawable sprite layer of a unit. Aliased to the Contracts `SpriteLayer` (the canonical seam
/// type) so a unit's resolved layers cross the `sim → render` boundary without conversion; `spriteIndex`
/// is the global value OpenDUNE's `viewport.c` computes.
public typealias UnitSpriteLayer = SpriteLayer

/// The body (+ optional turret + optional harvesting overlay) sprite layers for a unit.
public struct UnitSpriteInfo: Equatable, Sendable {
    public let body: UnitSpriteLayer
    public let turret: UnitSpriteLayer?
    /// The harvester "harvesting" overlay (`viewport.c:546`); non-nil only for a harvester actively
    /// harvesting on a spice tile.
    public let overlay: UnitSpriteLayer?

    public init(body: UnitSpriteLayer, turret: UnitSpriteLayer?, overlay: UnitSpriteLayer? = nil) {
        self.body = body
        self.turret = turret
        self.overlay = overlay
    }
}

/// Resolves the sprite layers to draw for a unit — a port of the per-unit drawing in OpenDUNE's
/// `GUI_Widget_Viewport_Draw` (`src/gui/viewport.c`): the body sprite (`groundSpriteID` + an
/// orientation-dependent frame offset per `displayMode`) and, for any unit with a `turretSpriteID`,
/// the turret (`turretSpriteID` + offset, oriented by `orientation[hasTurret ? 1 : 0]`, with a
/// per-type pixel offset). The viewer maps the global index to an SHP frame via the load-order bases.
public enum UnitSprites {
    /// `values_32A4` — UNIT/ROCKET directional (frames N,NE,E,SE,S; W half = E half mirrored).
    static let directional: [(offset: Int, flip: Bool)] =
        [ (0, false), (1, false), (2, false), (3, false), (4, false), (3, true), (2, true), (1, true) ]
    /// `values_32C4` — infantry (3 directions N,E,S).
    static let infantry: [(offset: Int, flip: Bool)] =
        [ (0, false), (1, false), (1, false), (1, false), (2, false), (1, true), (1, true), (1, true) ]
    /// `values_334A` — INFANTRY_3 animation sub-frame for `spriteOffset & 3`.
    static let infantry3Sub = [ 0, 1, 0, 2 ]
    /// `values_32E4` — AIR UNIT / ornithopter directional (3 frames N,NE,E; `flag` bit 0 = H-flip, bit 1
    /// = V-flip). The southern facings are northern frames flipped *vertically* — a separate layout from
    /// the ground `values_32A4`, used in `viewport.c`'s air-unit draw pass (winger units).
    static let airUnit: [(offset: Int, flag: Int)] =
        [ (0, 0), (1, 0), (2, 0), (1, 2), (0, 2), (1, 3), (2, 1), (1, 1) ]
    /// `values_3304` — AIR ROCKET, indexed by **16** orientations (missiles have a fine facing); the S
    /// half is the N half flipped vertically (flag bit 1).
    static let airRocket: [(offset: Int, flag: Int)] =
        [
            (0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (3, 2), (2, 2), (1, 2),
            (0, 2), (3, 3), (2, 3), (3, 3), (4, 1), (3, 1), (2, 1), (1, 1),
        ]
    /// `values_33AE` — ornithopter rotor sub-frame for `spriteOffset & 3`.
    static let ornithopterRotor = [ 2, 1, 0, 1 ]
    /// `values_334E` — the harvesting-overlay pixel offset per orientation (`viewport.c:546`).
    static let harvestOverlayOffset: [(Int, Int)] =
        [ (0, 7), (-7, 6), (-14, 1), (-9, -6), (0, -9), (9, -6), (14, 1), (7, 6) ]
    /// `values_336E` — siege-tank turret pixel offset per orientation.
    static let siegeTurretOffset: [(Int, Int)] =
        [ (0, -5), (0, -5), (2, -3), (2, -1), (-1, -3), (-2, -1), (-2, -3), (-1, -5) ]
    /// `values_338E` — devastator turret pixel offset per orientation.
    static let devastatorTurretOffset: [(Int, Int)] =
        [ (0, -4), (-1, -3), (2, -4), (0, -3), (-1, -3), (0, -3), (-2, -4), (1, -3) ]

    /// `onSpice` tells the resolver the harvester is standing on a spice / thick-spice tile — the
    /// landscape gate for the harvesting overlay (`viewport.c:546`). The caller resolves the landscape
    /// type (`UnitSprites` has no map); it is ignored for non-harvesters.
    public static func info(for unit: Unit, onSpice: Bool = false) -> UnitSpriteInfo? {
        guard let type = UnitType(rawValue: Int(unit.o.type)) else { return nil }

        let info = UnitInfo[type]

        let bodyO8 = Int(Orientation.to8(UInt8(bitPattern: unit.orientation[0].current)))
        var bodyIndex = Int(info.groundSpriteID)
        var flipH = false, flipV = false

        // Air units (`movementType == winger`: carryall, ornithopter, frigate, the missiles) are drawn by
        // a SEPARATE pass in `viewport.c` with their own tables — NOT the ground `values_32A4`. Ground and
        // air share `displayMode` but render completely differently.
        if info.movementType == .winger {
            switch info.displayMode {
                case .singleFrame:  // a bullet: 1 frame, +1 when "big"
                    if unit.o.flags.contains(.bulletIsBig) { bodyIndex += 1 }
                case .unit:  // carryall / frigate
                    let (off, flag) = airUnit[bodyO8]; bodyIndex += off
                    flipH = flag & 1 != 0; flipV = flag & 2 != 0
                case .rocket:  // missiles: 16-orientation
                    let o16 = Int(Orientation.to16(UInt8(bitPattern: unit.orientation[0].current)))
                    let (off, flag) = airRocket[o16]; bodyIndex += off
                    flipH = flag & 1 != 0; flipV = flag & 2 != 0
                case .ornithopter:  // 3 frames × rotor animation
                    let (off, flag) = airUnit[bodyO8]
                    bodyIndex += off * 3 + ornithopterRotor[Int(unit.spriteOffset) & 3]
                    flipH = flag & 1 != 0; flipV = flag & 2 != 0
                case .infantry3Frames, .infantry4Frames:
                    break
            }
            // The wing-beat: `hasAnimationSet` units alternate a second 5-frame block via `animationFlip`.
            if info.flags.contains(.hasAnimationSet) && unit.o.flags.contains(.animationFlip) { bodyIndex += 5 }
            // A carryall carrying a unit shows its loaded body (+3).
            if type == .carryall && unit.o.flags.contains(.inTransport) { bodyIndex += 3 }
        } else {
            switch info.displayMode {
                case .unit, .rocket:
                    if info.movementType == .slither { break }  // sandworm/sonic-blast: no directional frame
                    let (offset, flip) = directional[bodyO8]
                    bodyIndex += offset; flipH = flip
                case .infantry3Frames:
                    let (dir, flip) = infantry[bodyO8]
                    bodyIndex += dir * 3 + infantry3Sub[Int(unit.spriteOffset) & 3]; flipH = flip
                case .infantry4Frames:
                    let (dir, flip) = infantry[bodyO8]
                    bodyIndex += dir * 4 + (Int(unit.spriteOffset) & 3); flipH = flip
                case .singleFrame, .ornithopter:
                    break
            }
        }
        let body = UnitSpriteLayer(spriteIndex: bodyIndex, flipped: flipH, flippedV: flipV, offsetX: 0, offsetY: 0)

        var turret: UnitSpriteLayer?
        if info.turretSpriteID != 0xFFFF {
            let slot = info.o.flags.contains(.hasTurret) ? 1 : 0
            let turretO8 = Int(Orientation.to8(UInt8(bitPattern: unit.orientation[slot].current)))
            let (offset, flip) = directional[turretO8]
            let (dx, dy) = turretOffset(info.turretSpriteID, turretO8)
            turret = UnitSpriteLayer(
                spriteIndex: Int(info.turretSpriteID) + offset,
                flipped: flip,
                offsetX: dx,
                offsetY: dy
            )
        }

        // Harvesting overlay (`viewport.c:546`): a harvester actively harvesting (`actionID == HARVEST`,
        // `spriteOffset >= 0`) on a spice tile draws a third layer above its body — sprite
        // `(spriteOffset % 3) + 0xDF + values_32A4[o8].offset * 3`, offset by `values_334E[o8]`, with the
        // body's horizontal flip. `spriteOffset % 3` animates the gather; the caller advances `spriteOffset`.
        var overlay: UnitSpriteLayer?
        if onSpice && type == .harvester && unit.spriteOffset >= 0
            && unit.actionID == UInt8(ActionType.harvest.rawValue)
        {
            let (dirOffset, dirFlip) = directional[bodyO8]
            let (ox, oy) = harvestOverlayOffset[bodyO8]
            overlay = UnitSpriteLayer(
                spriteIndex: (Int(unit.spriteOffset) % 3) + 0xDF + dirOffset * 3,
                flipped: dirFlip,
                offsetX: ox,
                offsetY: oy
            )
        }
        return UnitSpriteInfo(body: body, turret: turret, overlay: overlay)
    }

    /// The per-type turret pixel offset (`viewport.c`'s switch on `turretSpriteID`).
    static func turretOffset(_ turretSpriteID: UInt16, _ orientation: Int) -> (Int, Int) {
        switch turretSpriteID {
            case 141: return (0, -2)  // sonic tank   (0x8D)
            case 146: return (0, -3)  // launcher / deviator (0x92)
            case 126: return siegeTurretOffset[orientation]  // siege tank   (0x7E)
            case 136: return devastatorTurretOffset[orientation]  // devastator (0x88)
            default: return (0, 0)  // combat tank, …
        }
    }
}
