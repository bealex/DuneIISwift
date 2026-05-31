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
                let tile = frame.tiles[ty * n + tx]
                let index = source.terrainTile(tile.groundSpriteIndex).map { $0[min(centre, $0.count - 1)] } ?? 0
                let c = palette.rgba8(Int(index))
                let o = (ty * n + tx) * 4
                rgba[o] = c.red; rgba[o + 1] = c.green; rgba[o + 2] = c.blue; rgba[o + 3] = 255
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
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let scale = side / Viewport.worldSize    // world points → minimap points
            Canvas { context, _ in
                let rect = CGRect(x: 0, y: 0, width: side, height: side)
                if let base = model.minimapBase {
                    context.draw(Image(decorative: base, scale: 1, orientation: .up), in: rect)
                } else {
                    context.fill(Path(rect), with: .color(.black))
                }
                // Unit dots: player house bright, others dim red.
                if let frame = model.lastFrame {
                    for unit in frame.units {
                        let x = Double(unit.positionX) * scale / 256
                        let y = Double(unit.positionY) * scale / 256
                        let mine = unit.house == model.playerHouse
                        context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2.5, height: 2.5)),
                                     with: .color(mine ? .green : .red))
                    }
                }
                // The viewport rectangle.
                let v = model.viewport.visibleWorldRect(viewSize: model.viewSize)
                let r = CGRect(x: v.minX * scale, y: v.minY * scale, width: v.width * scale, height: v.height * scale)
                context.stroke(Path(r.intersection(rect)), with: .color(.white), lineWidth: 1)
            }
            .frame(width: side, height: side)
            .background(.black)
            .gesture(SpatialTapGesture().onEnded { value in
                let world = Viewport.worldSize / side
                model.centerOn(worldX: Double(value.location.x) * world, worldY: Double(value.location.y) * world)
            })
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(8)
    }
}
