import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

@Suite("Minimap — terrain + unit / structure overlay renderer")
struct MinimapTests {

    // MARK: Helpers

    /// Solid-sand tile grid of the full 64×64 size.
    private func sandGrid() -> [Simulation.WorldSnapshot.Tile] {
        let cell = Simulation.WorldSnapshot.Tile(
            groundTileID: 0, overlayTileID: 0,
            houseID: 0, isUnveiled: true,
            hasUnit: false, hasStructure: false,
            hasAnimation: false, hasExplosion: false,
            objectRef: 0
        )
        return [Simulation.WorldSnapshot.Tile](repeating: cell, count: 64 * 64)
    }

    private func sandLandscape(_ cell: Simulation.WorldSnapshot.Tile) -> LandscapeType {
        .normalSand
    }

    private func redForAnyHouse(_ id: UInt8) -> Minimap.ColorRGBA {
        Minimap.ColorRGBA(r: 0xFF, g: 0, b: 0)
    }

    private func greenForAnyHouse(_ id: UInt8) -> Minimap.ColorRGBA {
        Minimap.ColorRGBA(r: 0, g: 0xFF, b: 0)
    }

    private func pixel(_ buffer: [UInt8], x: Int, y: Int) -> Minimap.ColorRGBA {
        let off = (y * 64 + x) * 4
        return Minimap.ColorRGBA(
            r: buffer[off    ], g: buffer[off + 1],
            b: buffer[off + 2], a: buffer[off + 3]
        )
    }

    // MARK: Terrain pass

    @Test("buffer length = 4 * 64 * 64 bytes")
    func bufferLength() {
        let buf = Minimap.render(
            tileGrid: sandGrid(), landscapeAt: sandLandscape,
            units: Simulation.UnitPool(), structures: Simulation.StructurePool(),
            houseColor: redForAnyHouse
        )
        #expect(buf.count == 4 * 64 * 64)
    }

    @Test("every pixel has alpha = 0xFF")
    func allOpaque() {
        let buf = Minimap.render(
            tileGrid: sandGrid(), landscapeAt: sandLandscape,
            units: Simulation.UnitPool(), structures: Simulation.StructurePool(),
            houseColor: redForAnyHouse
        )
        for i in 0..<(64 * 64) {
            #expect(buf[i * 4 + 3] == 0xFF)
        }
    }

    @Test("uniform sand grid → every pixel = terrainColor(.normalSand)")
    func sandEverywhere() {
        let buf = Minimap.render(
            tileGrid: sandGrid(), landscapeAt: sandLandscape,
            units: Simulation.UnitPool(), structures: Simulation.StructurePool(),
            houseColor: redForAnyHouse
        )
        let sand = Minimap.terrainColor(.normalSand)
        for y in 0..<64 {
            for x in 0..<64 {
                #expect(pixel(buf, x: x, y: y) == sand)
            }
        }
    }

    @Test("spice vs thick-spice vs mountain produce distinct colours")
    func terrainDiversity() {
        let s = Minimap.terrainColor(.spice)
        let t = Minimap.terrainColor(.thickSpice)
        let m = Minimap.terrainColor(.entirelyMountain)
        #expect(s != t)
        #expect(s != m)
        #expect(t != m)
    }

    @Test("short tileGrid still yields 16384-byte buffer with opaque tail")
    func shortGridTolerance() {
        let short = Array(sandGrid().prefix(100))
        let buf = Minimap.render(
            tileGrid: short, landscapeAt: sandLandscape,
            units: Simulation.UnitPool(), structures: Simulation.StructurePool(),
            houseColor: redForAnyHouse
        )
        #expect(buf.count == 4 * 64 * 64)
        #expect(buf[4 * 64 * 64 - 1] == 0xFF)
    }

    // MARK: Unit overlay

    @Test("single unit at tile (5, 10) paints house colour at that pixel")
    func unitOverlaySinglePixel() {
        var units = Simulation.UnitPool()
        _ = units.allocate(at: 0, type: 13 /* Trike */, houseID: 1)
        var u = units[0]
        u.positionX = 5 * 256 + 32     // anywhere inside tile 5
        u.positionY = 10 * 256 + 32
        units[0] = u

        let buf = Minimap.render(
            tileGrid: sandGrid(), landscapeAt: sandLandscape,
            units: units, structures: Simulation.StructurePool(),
            houseColor: redForAnyHouse
        )
        #expect(pixel(buf, x: 5, y: 10) == Minimap.ColorRGBA(r: 0xFF, g: 0, b: 0))
        // Neighbours unchanged.
        #expect(pixel(buf, x: 4, y: 10) == Minimap.terrainColor(.normalSand))
        #expect(pixel(buf, x: 6, y: 10) == Minimap.terrainColor(.normalSand))
    }

    @Test("freed unit slot does not paint")
    func freedSlotNoPaint() {
        var units = Simulation.UnitPool()
        _ = units.allocate(at: 0, type: 13, houseID: 1)
        var u = units[0]
        u.positionX = 5 * 256; u.positionY = 10 * 256
        units[0] = u
        units.free(at: 0)

        let buf = Minimap.render(
            tileGrid: sandGrid(), landscapeAt: sandLandscape,
            units: units, structures: Simulation.StructurePool(),
            houseColor: redForAnyHouse
        )
        #expect(pixel(buf, x: 5, y: 10) == Minimap.terrainColor(.normalSand))
    }

    @Test("projectile-type units (bullets / missiles) are skipped")
    func projectilesSkipped() {
        var units = Simulation.UnitPool()
        // Type 18 = BULLET; 20 = MISSILE_ROCKET — inside the 18..24 skip range.
        _ = units.allocate(at: 12, type: 18, houseID: 1)
        var u = units[12]
        u.positionX = 20 * 256; u.positionY = 20 * 256
        units[12] = u

        let buf = Minimap.render(
            tileGrid: sandGrid(), landscapeAt: sandLandscape,
            units: units, structures: Simulation.StructurePool(),
            houseColor: redForAnyHouse
        )
        #expect(pixel(buf, x: 20, y: 20) == Minimap.terrainColor(.normalSand))
    }

    // MARK: Structure overlay

    @Test("refinery footprint (3×2) paints 6 pixels with the house colour")
    func refineryFootprint() {
        var structures = Simulation.StructurePool()
        _ = structures.allocate(at: 0, type: 12 /* REFINERY */, houseID: 1)
        var s = structures[0]
        s.positionX = 10 * 256; s.positionY = 20 * 256
        structures[0] = s

        let buf = Minimap.render(
            tileGrid: sandGrid(), landscapeAt: sandLandscape,
            units: Simulation.UnitPool(), structures: structures,
            houseColor: greenForAnyHouse
        )
        let footprint = Simulation.Structures.footprintTiles(
            type: 12, anchorX: 10, anchorY: 20
        )
        #expect(footprint.count == 6)
        for (fx, fy) in footprint {
            #expect(pixel(buf, x: fx, y: fy) == Minimap.ColorRGBA(r: 0, g: 0xFF, b: 0))
        }
        // Outside the footprint still sand.
        #expect(pixel(buf, x: 9, y: 20) == Minimap.terrainColor(.normalSand))
    }

    @Test("slab / wall structures don't paint — they read as terrain")
    func slabsAndWallsSkipped() {
        var structures = Simulation.StructurePool()
        // Slab 1×1 (type 0) at tile (15, 15), wall (type 14) at (16, 15).
        _ = structures.allocate(at: 0, type: 0, houseID: 1)
        var a = structures[0]; a.positionX = 15 * 256; a.positionY = 15 * 256
        structures[0] = a
        _ = structures.allocate(at: 1, type: 14, houseID: 1)
        var b = structures[1]; b.positionX = 16 * 256; b.positionY = 15 * 256
        structures[1] = b

        let buf = Minimap.render(
            tileGrid: sandGrid(), landscapeAt: sandLandscape,
            units: Simulation.UnitPool(), structures: structures,
            houseColor: redForAnyHouse
        )
        #expect(pixel(buf, x: 15, y: 15) == Minimap.terrainColor(.normalSand))
        #expect(pixel(buf, x: 16, y: 15) == Minimap.terrainColor(.normalSand))
    }

    @Test("structure overlay paints over a unit at the same tile")
    func structurePaintsOverUnit() {
        var units = Simulation.UnitPool()
        _ = units.allocate(at: 0, type: 13, houseID: 1)
        var u = units[0]; u.positionX = 10 * 256; u.positionY = 20 * 256
        units[0] = u

        var structures = Simulation.StructurePool()
        _ = structures.allocate(at: 0, type: 12 /* REFINERY */, houseID: 1)
        var s = structures[0]; s.positionX = 10 * 256; s.positionY = 20 * 256
        structures[0] = s

        let unitColor = Minimap.ColorRGBA(r: 0xFF, g: 0, b: 0)
        let structColor = Minimap.ColorRGBA(r: 0, g: 0xFF, b: 0)
        let buf = Minimap.render(
            tileGrid: sandGrid(), landscapeAt: sandLandscape,
            units: units, structures: structures,
            houseColor: { id in id == 1 ? structColor : unitColor }
        )
        // Anchor tile of the refinery — should read as structColor, not unitColor.
        #expect(pixel(buf, x: 10, y: 20) == structColor)
    }

    // MARK: terrainColor sanity

    @Test("terrainColor distinguishes sand / rock / mountain / spice / slab")
    func terrainColorMatrix() {
        let sand = Minimap.terrainColor(.normalSand)
        let rock = Minimap.terrainColor(.entirelyRock)
        let mtn = Minimap.terrainColor(.entirelyMountain)
        let spice = Minimap.terrainColor(.spice)
        let slab = Minimap.terrainColor(.concreteSlab)
        let set: Set<[UInt8]> = [
            [sand.r, sand.g, sand.b],
            [rock.r, rock.g, rock.b],
            [mtn.r, mtn.g, mtn.b],
            [spice.r, spice.g, spice.b],
            [slab.r, slab.g, slab.b]
        ]
        // Five distinct colours.
        #expect(set.count == 5)
    }
}
