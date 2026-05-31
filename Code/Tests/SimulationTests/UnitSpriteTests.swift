import Testing
import DuneIIContracts
import DuneIIWorld
@testable import DuneIISimulation

/// Hand-derived checks of `UnitSprites.info` against OpenDUNE's `viewport.c` rules + the golden
/// `UnitInfo` sprite ids: body = `groundSpriteID` + orientation offset; turret = `turretSpriteID` +
/// offset (oriented by `orientation[1]` for tanks), with the per-type pixel offset.
@Suite("Unit sprite resolver")
struct UnitSpriteTests {
    private func unit(_ t: UnitType, orientation: Int8 = 0, turret: Int8 = 0) -> Unit {
        var u = Unit()
        u.o.type = UInt8(t.rawValue)
        u.o.flags = [.used, .allocated, .isUnit]
        u.orientation[0].current = orientation
        u.orientation[1].current = turret
        return u
    }

    @Test("tank: body + turret indices and orientation")
    func tank() throws {
        // groundSpriteID 111, turretSpriteID 116; hasTurret → turret uses orientation[1].
        let north = try #require(UnitSprites.info(for: unit(.tank, orientation: 0, turret: 0)))
        #expect(north.body == UnitSpriteLayer(spriteIndex: 111, flipped: false, offsetX: 0, offsetY: 0))
        #expect(north.turret == UnitSpriteLayer(spriteIndex: 116, flipped: false, offsetX: 0, offsetY: 0))

        // Orientation 64/256 = East (o8 = 2) → body offset 2, turret offset 2.
        let east = try #require(UnitSprites.info(for: unit(.tank, orientation: 64, turret: 64)))
        #expect(east.body.spriteIndex == 113)
        #expect(east.turret?.spriteIndex == 118)

        // Orientation 192/256 = West (o8 = 6) → offset 2, flipped.
        let west = try #require(UnitSprites.info(for: unit(.tank, orientation: Int8(truncatingIfNeeded: 192))))
        #expect(west.body.spriteIndex == 113)
        #expect(west.body.flipped)

        // Independent turret heading (orientation[1]) for hasTurret units.
        let split = try #require(UnitSprites.info(for: unit(.tank, orientation: 0, turret: 64)))
        #expect(split.body.spriteIndex == 111)
        #expect(split.turret?.spriteIndex == 118)
    }

    @Test("siege/devastator turret pixel offsets; sonic/launcher/deviator have turrets")
    func turretOffsets() throws {
        // Siege tank turret offset at North = values_336E[0] = (0, -5).
        let siege = try #require(UnitSprites.info(for: unit(.siegeTank)))
        #expect(siege.turret?.offsetX == 0 && siege.turret?.offsetY == -5)
        // Devastator at North = values_338E[0] = (0, -4).
        let dev = try #require(UnitSprites.info(for: unit(.devastator)))
        #expect(dev.turret?.offsetY == -4)
        // Sonic tank: -2y. Launcher / deviator: -3y (they share turret sprite 146).
        #expect(UnitSprites.info(for: unit(.sonicTank))?.turret?.offsetY == -2)
        #expect(UnitSprites.info(for: unit(.launcher))?.turret?.offsetY == -3)
        #expect(UnitSprites.info(for: unit(.deviator))?.turret?.offsetY == -3)
    }

    @Test("turret-less units have no turret layer")
    func noTurret() throws {
        for type in [UnitType.trike, .quad, .harvester, .mcv, .carryall, .infantry, .soldier] {
            #expect(UnitSprites.info(for: unit(type))?.turret == nil, "\(type) should have no turret")
        }
    }

    @Test("infantry body uses the 3-direction table")
    func infantry() throws {
        // Soldier (INFANTRY_3, groundSpriteID 311): North = dir 0 → groundSpriteID; East (o8 2) = dir 1 → +3.
        let north = try #require(UnitSprites.info(for: unit(.soldier, orientation: 0)))
        #expect(north.body.spriteIndex == 311)
        let east = try #require(UnitSprites.info(for: unit(.soldier, orientation: 64)))
        #expect(east.body.spriteIndex == 311 + 3)
    }

    @Test("harvester harvesting overlay (viewport.c:546): on spice + ACTION_HARVEST only")
    func harvestingOverlay() throws {
        func harvester(orientation: Int8, action: ActionType, spriteOffset: Int8) -> Unit {
            var u = unit(.harvester, orientation: orientation)
            u.actionID = UInt8(action.rawValue)
            u.spriteOffset = spriteOffset
            return u
        }
        // Harvesting on spice, North (o8 0): overlay index = (spriteOffset % 3) + 0xDF + values_32A4[0]*3,
        // offset values_334E[0] = (0, 7), the body's H-flip (none for North).
        let north = try #require(UnitSprites.info(for: harvester(orientation: 0, action: .harvest, spriteOffset: 2),
                                                  onSpice: true)?.overlay)
        #expect(north == UnitSpriteLayer(spriteIndex: (2 % 3) + 0xDF, flipped: false, offsetX: 0, offsetY: 7))
        // The frame animates with spriteOffset % 3 (0,1,2,0,…).
        for offset in Int8(0) ... 5 {
            let ov = try #require(UnitSprites.info(for: harvester(orientation: 0, action: .harvest, spriteOffset: offset),
                                                   onSpice: true)?.overlay)
            #expect(ov.spriteIndex == 0xDF + Int(offset) % 3)
        }
        // East (o8 2): values_32A4[2] = (2, false) → +2*3 = +6; offset values_334E[2] = (-14, 1).
        let east = try #require(UnitSprites.info(for: harvester(orientation: 64, action: .harvest, spriteOffset: 0),
                                                 onSpice: true)?.overlay)
        #expect(east == UnitSpriteLayer(spriteIndex: 0xDF + 6, flipped: false, offsetX: -14, offsetY: 1))
        // No overlay off spice, nor while not harvesting, nor with a negative (death) spriteOffset.
        #expect(UnitSprites.info(for: harvester(orientation: 0, action: .harvest, spriteOffset: 0), onSpice: false)?.overlay == nil)
        #expect(UnitSprites.info(for: harvester(orientation: 0, action: .move, spriteOffset: 0), onSpice: true)?.overlay == nil)
        #expect(UnitSprites.info(for: harvester(orientation: 0, action: .harvest, spriteOffset: -1), onSpice: true)?.overlay == nil)
        // A non-harvester on spice never gets the overlay.
        #expect(UnitSprites.info(for: unit(.tank), onSpice: true)?.overlay == nil)
    }

    @Test("body sprite matches OpenDUNE's viewport.c formula (ground + air pass) for EVERY unit × 8 dirs")
    func everyUnitEightDirections() throws {
        // The exact viewport.c tables — re-derived here independently of `UnitSprites` so a divergence is
        // caught. GROUND pass: values_32A4 / values_32C4. AIR pass (winger): values_32E4 / values_3304 (16
        // orientations) / values_33AE. flag bit 0 = H-flip, bit 1 = V-flip.
        let v32A4: [(Int, Bool)] = [(0, false), (1, false), (2, false), (3, false),
                                    (4, false), (3, true), (2, true), (1, true)]
        let v32C4: [(Int, Bool)] = [(0, false), (1, false), (1, false), (1, false),
                                    (2, false), (1, true), (1, true), (1, true)]
        let v32E4: [(Int, Int)] = [(0, 0), (1, 0), (2, 0), (1, 2), (0, 2), (1, 3), (2, 1), (1, 1)]
        let v3304: [(Int, Int)] = [(0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (3, 2), (2, 2), (1, 2),
                                   (0, 2), (3, 3), (2, 3), (3, 3), (4, 1), (3, 1), (2, 1), (1, 1)]
        let v33AE = [2, 1, 0, 1]
        let v334A = [0, 1, 0, 2]

        for type in UnitType.allCases {
            let info = UnitInfo[type]
            let base = Int(info.groundSpriteID)
            for o8 in 0 ..< 8 {
                let orient = o8 * 32
                var index = base, fH = false, fV = false
                if info.movementType == .winger {                       // air pass
                    switch info.displayMode {
                        case .singleFrame: break                        // bullet, not "big"
                        case .unit:
                            let (off, fl) = v32E4[o8]; index = base + off; fH = fl & 1 != 0; fV = fl & 2 != 0
                        case .rocket:
                            let o16 = ((orient + 8) / 16) & 0xF
                            let (off, fl) = v3304[o16]; index = base + off; fH = fl & 1 != 0; fV = fl & 2 != 0
                        case .ornithopter:
                            let (off, fl) = v32E4[o8]; index = base + off * 3 + v33AE[0]; fH = fl & 1 != 0; fV = fl & 2 != 0
                        case .infantry3Frames, .infantry4Frames: break
                    }
                } else {                                                // ground pass
                    switch info.displayMode {
                        case .unit, .rocket:
                            if info.movementType != .slither { index = base + v32A4[o8].0; fH = v32A4[o8].1 }
                        case .infantry3Frames: index = base + v32C4[o8].0 * 3 + v334A[0]; fH = v32C4[o8].1
                        case .infantry4Frames: index = base + v32C4[o8].0 * 4; fH = v32C4[o8].1
                        case .singleFrame, .ornithopter: break
                    }
                }
                let u = unit(type, orientation: Int8(truncatingIfNeeded: orient))
                let r = try #require(UnitSprites.info(for: u), "\(type) o8 \(o8): nil")
                #expect(r.body.spriteIndex == index, "\(type) o8 \(o8): frame \(r.body.spriteIndex) != \(index)")
                #expect(r.body.flipped == fH, "\(type) o8 \(o8): H-flip \(r.body.flipped) != \(fH)")
                #expect(r.body.flippedV == fV, "\(type) o8 \(o8): V-flip \(r.body.flippedV) != \(fV)")
            }
        }
    }

    @Test("missile (air winger) body uses the 16-orientation air-rocket table with V-flips, not values_32A4")
    func rocketDirections() throws {
        // A missile is MOVEMENT_WINGER → drawn by viewport.c's AIR pass: values_3304 indexed by the *16*
        // orientation (`Orientation.to16`), where the southern half is the northern frame flipped
        // VERTICALLY (flag bit 1) — NOT the ground values_32A4 horizontal mirror. Proven by the OpenDUNE
        // bitmap draw tool: a south-flying rocket = the N frame (base) + vertical flip = points DOWN. This
        // is the bug the user reported ("rockets travelling south drawn incorrectly").
        let base = Int(UnitInfo[.missileRocket].groundSpriteID)
        // (offset, flipH, flipV) per o8 0..7 — orient o8·32 → o16 = to16 = 0,2,4,6,8,10,12,14.
        let expected: [(Int, Bool, Bool)] = [
            (0, false, false),   // N
            (2, false, false),   // NE
            (4, false, false),   // E
            (2, false, true),    // SE  (NE frame, V-flipped)
            (0, false, true),    // S   (N frame, V-flipped → points down)
            (2, true,  true),    // SW
            (4, true,  false),   // W
            (2, true,  false)]   // NW
        for o8 in 0 ..< 8 {
            let orient = Int8(truncatingIfNeeded: o8 * 32)
            let info = try #require(UnitSprites.info(for: unit(.missileRocket, orientation: orient)))
            #expect(info.body.spriteIndex == base + expected[o8].0, "o8 \(o8) wrong frame")
            #expect(info.body.flipped == expected[o8].1, "o8 \(o8) wrong H-flip")
            #expect(info.body.flippedV == expected[o8].2, "o8 \(o8) wrong V-flip")
            #expect(info.turret == nil)                                    // rockets have no turret
        }
        // South (o8 4, orientation 128): the *north* frame, flipped vertically — the reported-bug case.
        let south = try #require(UnitSprites.info(for: unit(.missileRocket, orientation: Int8(truncatingIfNeeded: 128))))
        #expect(south.body.spriteIndex == base && south.body.flippedV && !south.body.flipped)
    }
}
