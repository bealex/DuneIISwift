import AppKit
import CoreGraphics
import DuneIIContracts
import DuneIIFormats
import DuneIIRenderer
import Foundation
import SwiftUI

/// The minimap: a downscaled terrain image with unit dots and the current viewport rectangle. Clicking
/// recentres the main map on the clicked world point.
enum Minimap {
    /// A 64×64 terrain image: each pixel is the palette colour of its tile's centre pixel. Built once per
    /// scenario (terrain barely changes); units + the viewport rect are drawn live over it.
    @MainActor
    static func baseImage(frame: FrameInfo, source: DecodedSpriteSource, palette: Palette) -> CGImage? {
        let n = 64
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        let ts = source.terrainTileSize
        let centre = (ts / 2) * ts + (ts / 2)
        for ty in 0 ..< n {
            for tx in 0 ..< n {
                let o = (ty * n + tx) * 4
                rgba[o + 3] = 255
                // Outside the playable rectangle: the unused border is black (matches the main map).
                guard frame.mapArea.contains(tileX: tx, tileY: ty) else { continue }
                let tile = frame.tiles[ty * n + tx]
                let index = source.terrainTile(tile.groundSpriteIndex).map { $0[min(centre, $0.count - 1)] } ?? 0
                let c = palette.rgba8(Int(index))
                rgba[o] = c.red; rgba[o + 1] = c.green; rgba[o + 2] = c.blue
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct MinimapView: View {
    @State var model: GameModel

    var body: some View {
        // Read the live, observed state in `body` so the Canvas redraws every tick (units/structures move,
        // the viewport pans) — establishing the observation dependency here is more reliable than inside the
        // Canvas drawing closure.
        let frame = model.lastFrame
        let viewport = model.viewport
        let playerHouse = model.playerHouse
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let scale = side / Viewport.worldSize    // world points → minimap points
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let rect = CGRect(x: 0, y: 0, width: side, height: side)
                    if let base = model.minimapBase {
                        context.draw(Image(decorative: base, scale: 1, orientation: .up), in: rect)
                    } else {
                        context.fill(Path(rect), with: .color(.black))
                    }
                    if let frame {
                        // Buildings first (footprint-ish squares), then unit dots on top. Mine = bright, foes dim.
                        for s in frame.structures {
                            let x = Double(s.positionX) * scale / 256
                            let y = Double(s.positionY) * scale / 256
                            let mine = s.house == playerHouse
                            context.fill(Path(CGRect(x: x, y: y, width: 3.5, height: 3.5)),
                                         with: .color(mine ? .cyan : .orange))
                        }
                        for unit in frame.units {
                            let x = Double(unit.positionX) * scale / 256
                            let y = Double(unit.positionY) * scale / 256
                            let mine = unit.house == playerHouse
                            context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2.5, height: 2.5)),
                                         with: .color(mine ? .green : .red))
                        }
                    }
                    // The viewport rectangle.
                    let v = viewport.visibleWorldRect(viewSize: model.viewSize)
                    let r = CGRect(x: v.minX * scale, y: v.minY * scale, width: v.width * scale, height: v.height * scale)
                    context.stroke(Path(r.intersection(rect)), with: .color(.white), lineWidth: 1)
                }
                .frame(width: side, height: side)
                // An AppKit click/drag layer: recentres the map on click and follows the cursor while
                // dragging — and works even when the minimap panel isn't the key window (first-mouse).
                MinimapMouse(side: side) { point in
                    let world = Viewport.worldSize / side
                    let x = min(max(0, Double(point.x)), side) * world
                    let y = min(max(0, Double(point.y)), side) * world
                    model.centerOn(worldX: x, worldY: y)
                }
                .frame(width: side, height: side)
            }
            .frame(width: side, height: side)
            .background(.black)
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(8)
    }
}

/// A transparent AppKit overlay that reports click + drag locations (in its own top-left-origin space) so
/// the minimap can recentre the map continuously. Accepts the first mouse, so a click registers even when
/// the (non-activating) tool panel isn't focused.
private struct MinimapMouse: NSViewRepresentable {
    let side: CGFloat
    let onPoint: (CGPoint) -> Void

    func makeNSView(context: Context) -> MinimapMouseView {
        let view = MinimapMouseView()
        view.onPoint = onPoint
        return view
    }

    func updateNSView(_ nsView: MinimapMouseView, context: Context) { nsView.onPoint = onPoint }
}

final class MinimapMouseView: NSView {
    var onPoint: ((CGPoint) -> Void)?

    override var isFlipped: Bool { true }   // top-left origin, matching the SwiftUI Canvas
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { report(event) }
    override func mouseDragged(with event: NSEvent) { report(event) }

    private func report(_ event: NSEvent) { onPoint?(convert(event.locationInWindow, from: nil)) }
}
