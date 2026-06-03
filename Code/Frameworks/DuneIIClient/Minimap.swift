import CoreGraphics
import DuneIIContracts
import DuneIIFormats
import DuneIIRenderer
import DuneIIWorld
import Foundation
import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

/// The minimap: a downscaled terrain image with unit dots and the current viewport rectangle. Clicking
/// recentres the main map on the clicked world point.
enum Minimap {
    /// A 64×64 terrain image: each pixel is the palette colour of its tile's centre pixel. Rebuilt by
    /// `GameModel.refreshMinimapBase` whenever the terrain tiles change (structures baking in, walls, craters,
    /// spice) — not just at load, or the minimap would show the starting map; units + the viewport rect are
    /// drawn live over it.
    @MainActor
    static func baseImage(frame: FrameInfo, source: DecodedSpriteSource, palette: Palette, showFog: Bool) -> CGImage? {
        let n = 64
        var rgba = [ UInt8 ](repeating: 0, count: n * n * 4)
        let ts = source.terrainTileSize
        let centre = (ts / 2) * ts + (ts / 2)
        for ty in 0 ..< n {
            for tx in 0 ..< n {
                let o = (ty * n + tx) * 4
                rgba[o + 3] = 255
                // Outside the playable rectangle: the unused border is black (matches the main map).
                guard frame.mapArea.contains(tileX: tx, tileY: ty) else { continue }
                let tile = frame.tiles[ty * n + tx]
                // Fog of war: an unexplored cell stays black (radar darkens what the player hasn't seen),
                // matching the main map's veil. Gated by `showFog`, like the renderer (`FrameComposer.cell`).
                if showFog && !tile.isUnveiled { continue }
                let index = source.terrainTile(tile.groundSpriteIndex).map { $0[min(centre, $0.count - 1)] } ?? 0
                let c = palette.rgba8(Int(index))
                rgba[o] = c.red
                rgba[o + 1] = c.green
                rgba[o + 2] = c.blue
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: n,
            height: n,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: n * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// The radar "tuning" animation (`STATIC.WSA`): the static-noise frames Dune II plays when radar comes
    /// online / goes dark. Decoded once; each frame is `width×height` palette indices → a `CGImage`.
    @MainActor
    static func radarStaticFrames(assets: AssetStore) -> [CGImage] {
        guard let data = assets.data("STATIC.WSA"), let anim = try? Wsa.Animation(data) else { return [] }
        let palette = anim.palette ?? assets.palette
        return anim.frames.compactMap {
            rgbaImage(indices: $0, width: anim.width, height: anim.height, palette: palette)
        }
    }

    /// A structure's tile footprint `(width, height)` — its minimap blip spans the whole footprint, not
    /// just the top-left corner tile (`positionX/Y` is the corner). Mirrors `GameScene.structureFootprint`.
    static func footprint(_ type: StructureType) -> (Int, Int) {
        let layout = StructureLayoutInfo[StructureInfo[type].layout]
        return (Int(layout.size.width), Int(layout.size.height))
    }

    /// Build a `CGImage` from `width×height` row-major palette indices.
    static func rgbaImage(indices: [UInt8], width: Int, height: Int, palette: Palette) -> CGImage? {
        guard width > 0, height > 0, indices.count >= width * height else { return nil }
        var rgba = [ UInt8 ](repeating: 0, count: width * height * 4)
        for i in 0 ..< width * height {
            let c = palette.rgba8(Int(indices[i]))
            let o = i * 4
            rgba[o] = c.red
            rgba[o + 1] = c.green
            rgba[o + 2] = c.blue
            rgba[o + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
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
        // Radar state (observed in `body` so the Canvas redraws on a transition). The minimap shows live
        // content only when the radar is up (or the debug override is on); during a transition it plays the
        // STATIC.WSA "tuning" frames; otherwise (radar offline) it's a dark screen.
        let staticFrames = model.radarStaticFrames
        let staticIndex = model.radarStaticFrameIndex
        let radarOn = model.forceMinimap || model.radarActive
        let showFog = model.showFog  // read here so the Canvas redraws when the fog toggle flips
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let scale = side / Viewport.worldSize  // world points → minimap points
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let rect = CGRect(x: 0, y: 0, width: side, height: side)
                    // Radar tuning in/out: the STATIC.WSA noise frame, stretched to fill.
                    if let staticIndex, staticIndex < staticFrames.count {
                        return context.draw(
                            Image(decorative: staticFrames[staticIndex], scale: 1, orientation: .up),
                            in: rect
                        )
                    }
                    // Radar offline (no outpost / no power) and not force-enabled — a dark, empty screen.
                    guard radarOn else { return context.fill(Path(rect), with: .color(.black)) }

                    if let base = model.minimapBase {
                        context.draw(Image(decorative: base, scale: 1, orientation: .up), in: rect)
                    } else {
                        context.fill(Path(rect), with: .color(.black))
                    }
                    if let frame {
                        // Only plot what's inside the playable rectangle — the base image blacks the border
                        // out, and units *can* sit in it (e.g. the Fremen palace wave scatters into the
                        // unplayable corner, faithfully to OpenDUNE), which otherwise shows as a stray corner
                        // blip. `mapArea` is the same clip the base terrain uses.
                        let area = frame.mapArea
                        // Blip placement + sizing both scale with the canvas: the 64-pixel-wide base image
                        // (one pixel per tile) fills `side`, so one tile is `side / 64` points. World positions
                        // are sub-tile units (256 per tile, `FrameComposer.imageX`), so a blip's point is
                        // `positionX / 256 * tile`. A structure spans its full tile footprint; a unit dot is
                        // ~0.7 tile — equal to the old fixed 2.5 points at the default panel size, now resizing.
                        // (Note: `scale` = `side / worldSize` is points-per-*world-pixel*, used only for the
                        // viewport rect below — it's 16× too small for tile-space blips, hence `tile` here.)
                        let tile = side / 64
                        let unitBlip = tile * (2.5 / 3.5)
                        // Buildings first (footprint-ish squares), then unit dots on top. Mine = bright, foes dim.
                        // Under fog (when shown), a blip on a still-veiled tile is hidden — the radar doesn't
                        // reveal what the player can't see (`isHiddenByFog`, same masking as the main map).
                        for s in frame.structures
                        where area.contains(tileX: s.positionX / 256, tileY: s.positionY / 256)
                            && !FrameComposer.isHiddenByFog(
                                frame,
                                worldX: s.positionX,
                                worldY: s.positionY,
                                showFog: showFog
                            )
                        {
                            let x = Double(s.positionX) * tile / 256
                            let y = Double(s.positionY) * tile / 256
                            let mine = s.house == playerHouse
                            // Span the building's full tile footprint, not just its top-left corner tile.
                            let (fw, fh) = Minimap.footprint(s.type)
                            context.fill(
                                Path(CGRect(x: x, y: y, width: Double(fw) * tile, height: Double(fh) * tile)),
                                with: .color(mine ? .cyan : .orange)
                            )
                        }
                        for unit in frame.units
                        where area.contains(tileX: unit.positionX / 256, tileY: unit.positionY / 256)
                            && !FrameComposer.isHiddenByFog(
                                frame,
                                worldX: unit.positionX,
                                worldY: unit.positionY,
                                showFog: showFog
                            )
                        {
                            let x = Double(unit.positionX) * tile / 256
                            let y = Double(unit.positionY) * tile / 256
                            let mine = unit.house == playerHouse
                            context.fill(
                                Path(
                                    ellipseIn: CGRect(
                                        x: x - unitBlip / 2,
                                        y: y - unitBlip / 2,
                                        width: unitBlip,
                                        height: unitBlip
                                    )
                                ),
                                with: .color(mine ? .green : .red)
                            )
                        }
                    }
                    // The viewport rectangle.
                    let v = viewport.visibleWorldRect(viewSize: model.viewSize)
                    let r = CGRect(
                        x: v.minX * scale,
                        y: v.minY * scale,
                        width: v.width * scale,
                        height: v.height * scale
                    )
                    context.stroke(Path(r.intersection(rect)), with: .color(.white), lineWidth: 1)
                }
                .frame(width: side, height: side)
                // An AppKit click/drag layer: recentres the map on click and follows the cursor while
                // dragging — and works even when the minimap panel isn't the key window (first-mouse). Only
                // active while the radar is up + settled (a dark / tuning screen isn't clickable, as in Dune II).
                if radarOn, staticIndex == nil {
                    #if os(macOS)
                        MinimapMouse(side: side) { point in
                            // Left click / drag: recentre the main map on the clicked world point.
                            let world = Viewport.worldSize / side
                            let x = min(max(0, Double(point.x)), side) * world
                            let y = min(max(0, Double(point.y)), side) * world
                            model.centerOn(worldX: x, worldY: y)
                        } onRightPoint: { point in
                            // Right click: order the selected unit(s) to that tile — same default order
                            // (move / attack / harvest) as right-clicking the big map (`rightClickTile`).
                            let tx = min(63, max(0, Int(Double(point.x) / side * 64)))
                            let ty = min(63, max(0, Int(Double(point.y) / side * 64)))
                            model.rightClickTile(tx, ty)
                        }
                        .frame(width: side, height: side)
                    #else
                        // iOS: tap/drag the radar to recentre the main map.
                        Color.clear.contentShape(Rectangle())
                            .frame(width: side, height: side)
                            .gesture(
                                DragGesture(minimumDistance: 0).onChanged { g in
                                    let world = Viewport.worldSize / side
                                    model.centerOn(
                                        worldX: min(max(0, g.location.x), side) * world,
                                        worldY: min(max(0, g.location.y), side) * world
                                    )
                                }
                            )
                    #endif
                }
            }
            .frame(width: side, height: side)
            .background(.black)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }
}

#if os(macOS)
    /// A transparent AppKit overlay that reports click + drag locations (in its own top-left-origin space) so
    /// the minimap can recentre the map continuously. Accepts the first mouse, so a click registers even when
    /// the (non-activating) tool panel isn't focused.
    private struct MinimapMouse: NSViewRepresentable {
        let side: CGFloat
        let onPoint: (CGPoint) -> Void
        let onRightPoint: (CGPoint) -> Void

        func makeNSView(context: Context) -> MinimapMouseView {
            let view = MinimapMouseView()
            view.onPoint = onPoint
            view.onRightPoint = onRightPoint
            return view
        }

        func updateNSView(_ nsView: MinimapMouseView, context: Context) {
            nsView.onPoint = onPoint
            nsView.onRightPoint = onRightPoint
        }
    }

    final class MinimapMouseView: NSView {
        var onPoint: ((CGPoint) -> Void)?
        var onRightPoint: ((CGPoint) -> Void)?

        override var isFlipped: Bool { true }  // top-left origin, matching the SwiftUI Canvas
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { report(event) }
        override func mouseDragged(with event: NSEvent) { report(event) }
        // Middle button click / drag recentres + follows the cursor too (like the big map's middle-button pan).
        override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { report(event) } }
        override func otherMouseDragged(with event: NSEvent) { if event.buttonNumber == 2 { report(event) } }
        // Right click / drag issues a unit order at that point (same as the big map's right-click).
        override func rightMouseDown(with event: NSEvent) { reportRight(event) }
        override func rightMouseDragged(with event: NSEvent) { reportRight(event) }

        private func report(_ event: NSEvent) { onPoint?(convert(event.locationInWindow, from: nil)) }
        private func reportRight(_ event: NSEvent) { onRightPoint?(convert(event.locationInWindow, from: nil)) }
    }
#endif
