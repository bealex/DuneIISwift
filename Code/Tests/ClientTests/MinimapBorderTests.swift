import CoreGraphics
import DuneIIContracts
import SwiftUI
import Testing

@testable import DuneIIClient

/// `Minimap.borderRing` is the pure geometry behind the minimap's map-boundary ring (the concrete border
/// mirror): a one-tile band immediately outside the playable rectangle. Verify it sits where the main map's
/// border sits — outset by exactly one tile — and is a real (non-empty) ring.
struct MinimapBorderTests {
    @Test func ringIsOneTileOutsideThePlayableRect() {
        let area = FrameInfo.MapArea(minX: 1, minY: 2, width: 60, height: 58)
        let tile: CGFloat = 4  // a 256pt minimap ⇒ 256/64

        let bounds = Minimap.borderRing(area: area, tile: tile).boundingRect
        // The ring's outer edge is the playable rect outset by one tile in every direction.
        #expect(bounds.minX == CGFloat(area.minX - 1) * tile)
        #expect(bounds.minY == CGFloat(area.minY - 1) * tile)
        #expect(bounds.width == CGFloat(area.width + 2) * tile)
        #expect(bounds.height == CGFloat(area.height + 2) * tile)
    }

    @Test func ringIsNonEmptyForTheFullGrid() {
        // Even the full 64×64 grid yields a valid (if off-canvas) ring path — never an empty/degenerate one.
        let ring = Minimap.borderRing(area: .full, tile: 4)
        #expect(!ring.isEmpty)
        #expect(ring.boundingRect.width == CGFloat(66 * 4))
    }
}
