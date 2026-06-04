import CoreGraphics

/// The camera over the 64×64 map: a `center` (world point shown at the screen centre) + a `zoom`
/// magnification. The world is `64 · tilePx = 1024` world points; at `zoom == 1` one tile's source pixel
/// maps to one point ("pixel-to-point"), at `zoom == n` a tile is `tilePx · n` points. The renderer draws
/// at the base tile size; `SKCameraNode.setScale(1/zoom)` applies the magnification and `position = center`
/// the scroll. Pure value type — the coordinate mapping is independent of any view.
struct Viewport: Equatable {
    static let tilePx = 16.0
    static let tiles = 64.0
    static let worldSize = tilePx * tiles  // 1024 world points

    /// Screen centre in **world points** (0…worldSize, y-down to match image space).
    var centerX: Double = worldSize / 2
    var centerY: Double = worldSize / 2
    /// Magnification, clamped to `[minZoom, maxZoom]`.
    var zoom: Double = 2

    /// The scenario's playable rectangle in **world points** (image space, y-down) — the camera clamps to
    /// this, so it never scrolls onto the unused map border. Defaults to the full 64×64 world; set from the
    /// frame's `mapArea` on load. (`MapBounds.md`.)
    var area = CGRect(x: 0, y: 0, width: worldSize, height: worldSize)

    static let minZoom = 1.0
    static let maxZoom = 16.0

    mutating func setZoom(_ z: Double) { zoom = min(Self.maxZoom, max(Self.minZoom, z)) }

    mutating func zoomIn() { setZoom(zoom * 2) }

    mutating func zoomOut() { setZoom(zoom / 2) }

    /// Scroll by `dx`/`dy` **screen points** (so the felt speed is constant across zoom levels).
    mutating func scroll(dx: Double, dy: Double, viewSize: CGSize) {
        centerX += dx / zoom
        centerY += dy / zoom
        clamp(viewSize: viewSize)
    }

    /// Centre the view on a world point (e.g. a minimap click).
    mutating func center(onWorldX x: Double, worldY y: Double, viewSize: CGSize) {
        centerX = x; centerY = y
        clamp(viewSize: viewSize)
    }

    /// The world rectangle currently visible in a view of `viewSize` points (image space, y-down).
    func visibleWorldRect(viewSize: CGSize) -> CGRect {
        let w = Double(viewSize.width) / zoom, h = Double(viewSize.height) / zoom
        return CGRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h)
    }

    /// Keep the **playable area** on screen: when it's wider/taller than the view, clamp so its edge can't
    /// pull past the view edge; when it's smaller (zoomed out past 1:1), pin the centre on the area so it sits
    /// centred (the surrounding border is left black). Clamps to `area`, not the full world — so the camera
    /// follows the scenario's map boundary rather than scrolling onto the unused border.
    mutating func clamp(viewSize: CGSize) {
        let half = Double(viewSize.width) / zoom / 2
        if half * 2 >= area.width {
            centerX = area.midX
        } else {
            centerX = min(area.maxX - half, max(area.minX + half, centerX))
        }
        let halfY = Double(viewSize.height) / zoom / 2
        if halfY * 2 >= area.height {
            centerY = area.midY
        } else {
            centerY = min(area.maxY - halfY, max(area.minY + halfY, centerY))
        }
    }
}
