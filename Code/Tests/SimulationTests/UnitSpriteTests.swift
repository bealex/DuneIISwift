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

    @Test("rocket body mirrors the western half (values_32A4), all 8 orientations")
    func rocketDirections() throws {
        // missileRocket = type 19 = "Rocket", DISPLAYMODE_ROCKET, groundSpriteID 278. Same rule as a
        // tank body: index += values_32A4[o8][0], flip = values_32A4[o8][1] — the W half is the E half
        // mirrored. orientation 0/32/64/.../224 = o8 0..7 (each step is 32/256).
        let base = Int(UnitInfo[.missileRocket].groundSpriteID)            // 278
        // (offset, flip) per o8: {0,0},{1,0},{2,0},{3,0},{4,0},{3,1},{2,1},{1,1}
        let expected: [(Int, Bool)] = [(0, false), (1, false), (2, false), (3, false),
                                       (4, false), (3, true), (2, true), (1, true)]
        for o8 in 0 ..< 8 {
            let orient = Int8(truncatingIfNeeded: o8 * 32)
            let info = try #require(UnitSprites.info(for: unit(.missileRocket, orientation: orient)))
            #expect(info.body.spriteIndex == base + expected[o8].0, "o8 \(o8) wrong frame")
            #expect(info.body.flipped == expected[o8].1, "o8 \(o8) wrong flip")
            #expect(info.turret == nil)                                    // rockets have no turret
        }
        // West (o8 6, orientation 192/-64): the East frame (base+2) mirrored.
        let west = try #require(UnitSprites.info(for: unit(.missileRocket, orientation: Int8(truncatingIfNeeded: 192))))
        #expect(west.body.spriteIndex == base + 2 && west.body.flipped)
    }
}
