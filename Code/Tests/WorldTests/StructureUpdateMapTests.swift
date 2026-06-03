import Foundation
import Testing
import DuneIIContracts
import DuneIIFormats
@testable import DuneIIWorld

/// `Structure_UpdateMap` (`structure.c`) — stamping a structure's tiles. In particular the overlay clear
/// (`if (Tile_IsUnveiled(t->overlayTileID)) t->overlayTileID = 0`): a building covers any real overlay
/// (a missile crater / wall) on its footprint, so the crater isn't drawn on top of it.
@Suite("Structure_UpdateMap overlay clear")
struct StructureUpdateMapTests {
    private func loadedState() throws -> GameState {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let iconMap = try IconMap(Data(contentsOf: root.appendingPathComponent("Resources/Tiles/Maps/ICON.MAP")))
        var s = GameState()
        s.iconMap = iconMap
        s.tileIDs = TileIDs(iconMap: iconMap) ?? TileIDs()
        return s
    }

    /// `Tile_IsUnveiled(overlay)` — true for a real overlay (crater/wall), false inside the 16-tile fog run.
    private func isUnveiledOverlay(_ o: UInt16, veiled: UInt16) -> Bool { o > veiled || o < veiled &- 15 }

    private func placeTurret(_ s: inout GameState, at packed: UInt16) -> Int {
        let slot = s.structureAllocate(index: Pool.structureIndexInvalid, type: UInt8(StructureType.turret.rawValue))!
        s.structures[slot].o.position = Tile32.unpack(packed)
        s.structures[slot].state = .idle
        return slot
    }

    @Test("a missile crater left on the building's tile is cleared (not drawn over the turret)")
    func clearsCraterUnderStructure() throws {
        var s = try loadedState()
        let packed = UInt16(20 * 64 + 20)
        let slot = placeTurret(&s, at: packed)
        // A real (unveiled) overlay — a crater — sitting on the tile before the building stamps it.
        s.map[Int(packed)].overlayTileID = 5
        #expect(isUnveiledOverlay(5, veiled: s.tileIDs.veiled))   // sanity: 5 is a real overlay (not fog)
        s.structureUpdateMap(slot)
        #expect(s.map[Int(packed)].overlayTileID == 0)   // cleared — the crater no longer renders on the turret
        #expect(s.map[Int(packed)].hasStructure)
    }

    @Test("a fog-veil overlay on the tile is left intact (only real overlays are cleared)")
    func keepsFogVeilOverlay() throws {
        var s = try loadedState()
        let veil = UInt8(truncatingIfNeeded: Int(s.tileIDs.veiled))   // the full fog-veil tile (< 256)
        let packed = UInt16(22 * 64 + 22)
        let slot = placeTurret(&s, at: packed)
        s.map[Int(packed)].overlayTileID = veil
        #expect(!isUnveiledOverlay(s.tileIDs.veiled, veiled: s.tileIDs.veiled))   // sanity: the veil isn't "unveiled"
        s.structureUpdateMap(slot)
        #expect(s.map[Int(packed)].overlayTileID == veil)     // preserved
    }
}
