import Testing
import DuneIIWorld
@testable import DuneIISimulation

/// Behaviour checks for the fog primitives `Tile_IsUnveiled` (`sprites.c:477`) and
/// `Map_IsPositionUnveiled` (`map.c:341`). The 16 tiles ending at `veiledTileID` are the veil frames;
/// everything above the run, or below its start, is unveiled terrain. A position counts as unveiled
/// only when its `isUnveiled` flag is set *and* its overlay is a non-veil sprite.
@Suite("Fog-of-war unveil primitives")
struct UnveilTests {
    let map: any MapPrimitives = DefaultMapPrimitives()
    let veiled: UInt16 = 124   // the real FOG_OF_WAR base from ICON.MAP

    @Test("Tile_IsUnveiled: the 16-frame veil run is veiled, outside it is unveiled")
    func tileIsUnveiled() {
        #expect(!map.tileIsUnveiled(veiled, veiledTileID: veiled))        // last veil frame
        #expect(!map.tileIsUnveiled(veiled - 15, veiledTileID: veiled))   // first veil frame
        #expect(!map.tileIsUnveiled(veiled - 8, veiledTileID: veiled))    // mid-run
        #expect(map.tileIsUnveiled(veiled + 1, veiledTileID: veiled))     // above the run
        #expect(map.tileIsUnveiled(veiled - 16, veiledTileID: veiled))    // below the run
        #expect(map.tileIsUnveiled(0, veiledTileID: veiled))              // ordinary terrain
    }

    @Test("Map_IsPositionUnveiled: needs the flag and a non-veil overlay")
    func isPositionUnveiled() {
        var ids = TileIDs(); ids.veiled = veiled
        func tile(unveiled: Bool, overlay: UInt8) -> MapTile {
            var t = MapTile(); t.isUnveiled = unveiled; t.overlayTileID = overlay; return t
        }
        // overlay 0 is below the veil run → an unveiled overlay; combined with the flag → visible.
        #expect(map.isPositionUnveiled(tile(unveiled: true, overlay: 0), tileIDs: ids))
        // Flag clear → never unveiled, whatever the overlay.
        #expect(!map.isPositionUnveiled(tile(unveiled: false, overlay: 0), tileIDs: ids))
        // Flagged, but the overlay is a veil frame (overlay is 7-bit; veil base 124 - 8 = 116) → hidden.
        #expect(!map.isPositionUnveiled(tile(unveiled: true, overlay: UInt8(veiled - 8)), tileIDs: ids))
    }
}
