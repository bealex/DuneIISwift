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

    /// The map-boundary ring: a one-tile-wide band immediately **outside** the playable rectangle (`mapArea`),
    /// mirroring the main map's concrete border (`Viewport.borderPx` = one tile). An even-odd-filled path
    /// (outer rect minus the playable rect) so only the ring is painted, never the playable terrain.
    static func borderRing(area: FrameInfo.MapArea, tile: CGFloat) -> Path {
        let inner = CGRect(
            x: CGFloat(area.minX) * tile,
            y: CGFloat(area.minY) * tile,
            width: CGFloat(area.width) * tile,
            height: CGFloat(area.height) * tile
        )
        var path = Path(inner.insetBy(dx: -tile, dy: -tile))
        path.addRect(inner)
        return path
    }

    /// A structure's tile footprint `(width, height)` — its minimap blip spans the whole footprint, not
    /// just the top-left corner tile (`positionX/Y` is the corner). Mirrors `GameScene.structureFootprint`.
    static func footprint(_ type: StructureType) -> (Int, Int) {
        let layout = StructureLayoutInfo[StructureInfo[type].layout]
        return (Int(layout.size.width), Int(layout.size.height))
    }

    /// Whether a unit of `type` is plotted on the minimap. Projectiles (bullets, rockets, the sonic blast —
    /// every `.isBullet` type) are skipped: they're transient and clutter the radar. Real units (incl.
    /// sandworms, wingers, the frigate) still show.
    static func showsOnMinimap(_ type: UnitType) -> Bool { !UnitInfo[type].flags.contains(.isBullet) }

    /// Build a `CGImage` from `width×height` row-major palette indices.
    static func rgbaImage(indices: [UInt8], width: Int, height: Int, palette: Palette) -> CGImage? {
        guard width > 0, height > 0, indices.count >= width * height else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
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
    var model: GameModel

    var body: some View {
        // Read the live, observed state in `body` so the Canvas redraws every tick (units/structures move,
        // the viewport pans) — establishing the observation dependency here is more reliable than inside the
        // Canvas drawing closure. `minimapVersion` is the per-tick redraw token (bumped whenever `lastFrame`
        // republishes); `lastFrame` itself is `@ObservationIgnored`, so it's read imperatively for the data.
        let _ = model.minimapVersion
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
        // The radar-OFF background is palette colour 12 (OpenDUNE `GUI_Widget_Viewport_DrawTile`'s default), not
        // black — used in the offline branch below.
        let c12 = model.assets.palette.rgba8(12)
        let colour12 = Color(
            .sRGB,
            red: Double(c12.red) / 255,
            green: Double(c12.green) / 255,
            blue: Double(c12.blue) / 255
        )
        // The concrete map-boundary ring colour (the slab tile's minimap pixel) — drawn around the playable
        // rectangle in every radar state so the map limits are always visible, matching the main map's border.
        let borderColour = model.assets.concreteMinimapColor().map {
            Color(.sRGB, red: Double($0.red) / 255, green: Double($0.green) / 255, blue: Double($0.blue) / 255)
        }
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
                    // Radar offline (no outpost / no power) and not force-enabled. Not a black screen: OpenDUNE
                    // fills the playable area with palette colour 12 and still plots the player's *own*
                    // structures (`GUI_Widget_Viewport_DrawTile`'s radar-off branch — no terrain, no enemies, no
                    // fog test). The unplayable border stays black; the viewport rectangle is still drawn.
                    guard
                        radarOn
                    else {
                        context.fill(Path(rect), with: .color(.black))
                        let tile = side / 64
                        if let frame {
                            let area = frame.mapArea
                            context.fill(
                                Path(
                                    CGRect(
                                        x: Double(area.minX) * tile,
                                        y: Double(area.minY) * tile,
                                        width: Double(area.width) * tile,
                                        height: Double(area.height) * tile
                                    )
                                ),
                                with: .color(colour12)
                            )
                            for s in frame.structures
                            where s.house == playerHouse
                                && area.contains(tileX: s.positionX / 256, tileY: s.positionY / 256)
                            {
                                let (fw, fh) = Minimap.footprint(s.type)
                                context.fill(
                                    Path(
                                        CGRect(
                                            x: Double(s.positionX) * tile / 256,
                                            y: Double(s.positionY) * tile / 256,
                                            width: Double(fw) * tile,
                                            height: Double(fh) * tile
                                        )
                                    ),
                                    with: .color(.cyan)
                                )
                            }
                            if let borderColour {
                                context.fill(
                                    Minimap.borderRing(area: frame.mapArea, tile: side / 64),
                                    with: .color(borderColour),
                                    style: FillStyle(eoFill: true)
                                )
                            }
                        }
                        let v = viewport.visibleWorldRect(viewSize: model.viewSize)
                        let vr = CGRect(
                            x: v.minX * scale,
                            y: v.minY * scale,
                            width: v.width * scale,
                            height: v.height * scale
                        )
                        context.stroke(Path(vr.intersection(rect)), with: .color(.white), lineWidth: 1)
                        return
                    }

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
                        where Minimap.showsOnMinimap(unit.type)
                            && area.contains(tileX: unit.positionX / 256, tileY: unit.positionY / 256)
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
                        if let borderColour {
                            context.fill(
                                Minimap.borderRing(area: area, tile: tile),
                                with: .color(borderColour),
                                style: FillStyle(eoFill: true)
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
                // An AppKit click/drag layer: a primary click recentres the map (or, when a unit order is
                // armed, confirms the move/attack/harvest at that tile — the minimap doubles as a target
                // picker); a right click issues the default order. Works even when the panel isn't the key
                // window (first-mouse). Active whenever the minimap is settled — only the tuning animation
                // (`staticIndex`) blocks it, so navigation/targeting work even before the radar is online.
                if staticIndex == nil {
                    #if os(macOS)
                        MinimapMouse(side: side) { point in
                            // Left click / drag: recentre on the clicked point, or confirm an armed order there.
                            let tx = min(63, max(0, Int(Double(point.x) / side * 64)))
                            let ty = min(63, max(0, Int(Double(point.y) / side * 64)))
                            let world = Viewport.worldSize / side
                            model.minimapPrimaryClick(
                                tileX: tx,
                                tileY: ty,
                                worldX: min(max(0, Double(point.x)), side) * world,
                                worldY: min(max(0, Double(point.y)), side) * world
                            )
                        } onRightPoint: { point in
                            // Right click: order the selected unit(s) to that tile — same default order
                            // (move / attack / harvest) as right-clicking the big map (`rightClickTile`).
                            let tx = min(63, max(0, Int(Double(point.x) / side * 64)))
                            let ty = min(63, max(0, Int(Double(point.y) / side * 64)))
                            model.rightClickTile(tx, ty)
                        }
                        .frame(width: side, height: side)
                    #else
                        // iOS: tap/drag the radar to recentre the main map — or, with an order armed, tap to
                        // confirm the target. `highPriorityGesture` so it wins over the enclosing sidebar
                        // ScrollView's pan; `minimumDistance: 0` ⇒ `onChanged` fires on touch-down, so a plain
                        // tap acts immediately (and a drag scrubs the view when not targeting).
                        Color.clear.contentShape(Rectangle())
                            .frame(width: side, height: side)
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 0).onChanged { g in
                                    let tx = min(63, max(0, Int(g.location.x / side * 64)))
                                    let ty = min(63, max(0, Int(g.location.y / side * 64)))
                                    let world = Viewport.worldSize / side
                                    model.minimapPrimaryClick(
                                        tileX: tx,
                                        tileY: ty,
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
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
