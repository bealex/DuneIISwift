import Foundation
import Testing
@testable import DuneIICore

@Suite("Orientation helpers (256→8, octantFrame)")
struct OrientationTests {
    @Test("Orientation.to8 maps N/E/S/W to 0/2/4/6")
    func cardinalOctants() {
        // North = 0, East = 64, South = 128 (unsigned interpretation),
        // West = -64 / 192. Check the ((o+16)/32)&7 formula.
        #expect(Orientation.to8(0) == 0)
        #expect(Orientation.to8(64) == 2)
        #expect(Orientation.to8(-128) == 4)   // 128 unsigned → octant 4
        #expect(Orientation.to8(-64) == 6)    // 192 unsigned → octant 6
    }

    @Test("Orientation.to8 rounds at the boundary (+16 half-octant)")
    func octantRounding() {
        // 15 is within 16 of north → bucket 0. 16 and up flip to bucket 1.
        #expect(Orientation.to8(15) == 0)
        #expect(Orientation.to8(16) == 1)
        // 47 is still NE; 48 flips to E.
        #expect(Orientation.to8(47) == 1)
        #expect(Orientation.to8(48) == 2)
    }

    @Test("octantFrame mirrors W-side octants against E-side ones")
    func octantFrameTable() {
        // OpenDUNE values_32A4 — the SW/W/NW octants re-use SE/E/NE
        // frames mirrored horizontally.
        #expect(Orientation.octantFrame.count == 8)
        #expect(Orientation.octantFrame[0] == (offset: 0, flipHorizontal: false))
        #expect(Orientation.octantFrame[2] == (offset: 2, flipHorizontal: false))
        #expect(Orientation.octantFrame[5] == (offset: 3, flipHorizontal: true))
        #expect(Orientation.octantFrame[6] == (offset: 2, flipHorizontal: true))
        #expect(Orientation.octantFrame[7] == (offset: 1, flipHorizontal: true))
    }
}

@Suite("Simulation.UnitInfo sprite-ID + displayMode")
struct UnitInfoSpriteTests {
    @Test("Ground sprite IDs match OpenDUNE's Sprites_Load numbering")
    func groundSpriteIDs() {
        // Carryall is in UNITS.SHP at offset 283.
        #expect(Simulation.UnitInfo.lookup(0)?.groundSpriteID == 283)
        // Tank (type 9) is in UNITS2.SHP at offset 111.
        #expect(Simulation.UnitInfo.lookup(9)?.groundSpriteID == 111)
        // Trike (13) is in UNITS.SHP at 243.
        #expect(Simulation.UnitInfo.lookup(13)?.groundSpriteID == 243)
        // Harvester (16) at 248.
        #expect(Simulation.UnitInfo.lookup(16)?.groundSpriteID == 248)
        // MCV (17) at 253.
        #expect(Simulation.UnitInfo.lookup(17)?.groundSpriteID == 253)
    }

    @Test("Display modes cover the three broad families")
    func displayModes() {
        #expect(Simulation.UnitInfo.lookup(0)?.displayMode == .unit)              // Carryall
        #expect(Simulation.UnitInfo.lookup(1)?.displayMode == .ornithopter)       // 'Thopter
        #expect(Simulation.UnitInfo.lookup(2)?.displayMode == .infantry4)         // Infantry squad
        #expect(Simulation.UnitInfo.lookup(4)?.displayMode == .infantry3)         // Soldier
        #expect(Simulation.UnitInfo.lookup(18)?.displayMode == .rocket)           // House missile
        #expect(Simulation.UnitInfo.lookup(23)?.displayMode == .singleFrame)      // Bullet
    }
}
