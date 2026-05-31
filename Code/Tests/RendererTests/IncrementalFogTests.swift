import Testing
import DuneIIContracts
import DuneIIFormats
@testable import DuneIIRenderer

/// Regression for the incremental fog frontier: `SpriteKitRenderer` repaints only changed cells via a cached
/// per-cell texture, and that cache key must include the **fog-edge** sprite. Without it, two cells with the
/// same ground/overlay/house but different fog-edge masks collide in the cache, so a cell re-textured as a
/// unit reveals neighbours gets a *stale* edge — fog looks wrong while moving, but a full rebuild (toggling
/// fog off/on) fixes it (the rebuild path doesn't use this cache). See insight `render-incremental-appearance-key`.
@Suite("Incremental fog")
struct IncrementalFogTests {
    /// Distinguishable 4×4 terrain tiles (pixels = the tile id); no unit frames.
    private struct FakeSource: WorldSpriteSource {
        var terrainTileSize: Int { 4 }
        func terrainTile(_ id: Int) -> [UInt8]? {
            id == 0 ? nil : [UInt8](repeating: UInt8(truncatingIfNeeded: id), count: 16)
        }
        func unitFrame(globalIndex: Int) -> SpriteFrame? { nil }
    }

    private func palette() -> Palette { Palette(colors: (0 ..< 256).map { .init(red: UInt8($0), green: UInt8($0), blue: UInt8($0)) }) }

    /// A 2×2 map, all ground id 5, revealed, with the given per-cell fog-edge sprite ids.
    private func frame(_ edges: [Int]) -> FrameInfo {
        let tiles = edges.map {
            FrameInfo.Tile(groundSpriteIndex: 5, overlaySpriteIndex: 0, houseID: 0, isUnveiled: true, fogEdgeSpriteIndex: $0)
        }
        return FrameInfo(tick: 0, mapWidth: 2, mapHeight: 2, tiles: tiles, units: [], structures: [],
                         effects: [], houses: [], viewportX: 0, viewportY: 0, veiledTileIndex: 99)
    }

    @MainActor
    @Test("a cell re-textured with a new fog edge does not reuse another cell's cached edge")
    func fogEdgeCacheKey() {
        let renderer = SpriteKitRenderer(source: FakeSource(), basePalette: palette(), showFog: true)
        renderer.render(frame([0, 0, 0, 0]))      // baseline: all clear (no dirty cells)
        renderer.render(frame([8, 0, 0, 0]))      // cell 0 gains fog-edge sprite 8 → cached under its ground key
        renderer.render(frame([8, 9, 0, 0]))      // cell 1 gains a *different* edge (9) with the same ground

        // Two distinct edges over the same ground ⇒ two distinct cached textures. With the bug (fog edge
        // absent from the cache key) cell 1 reuses cell 0's texture and the count stays 1.
        #expect(renderer.cachedTileTextureCount >= 2)
    }
}
