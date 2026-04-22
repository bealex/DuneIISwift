import Foundation
import CoreGraphics
import AppKit
import DuneIICore

/// Pure-CoreGraphics compositor that renders a tile rectangle of a
/// live `ScenarioRuntime` into a `CGImage`. The output is identical
/// (up to rasterisation rounding) to what `ScenarioScene` draws for
/// the same rectangle: ground tiles first, then per-structure
/// house-colour outlines, then unit sprites, then a selection halo
/// for whichever entity the runtime's selection state points at.
///
/// Drives two clients:
///  - `duneii-headless`'s `screenshot` command (on-disk PNG).
///  - `ScreenshotTests` (golden-image comparison).
///
/// Not a 1:1 port of `ScenarioScene`'s rendering. Intentionally omits:
///  - animated overlays (explosions, fog, rally markers, placement
///    ghost, toasts).
///  - map-edge banners + HUD + sidebar.
/// Everything that drives regression tests — terrain, structure
/// footprints, units, halos — is captured faithfully.
@MainActor
public final class ScreenshotRenderer {
    public static let tilePixels: Int = 16

    private let loader: AssetLoader
    private var icnCache: [CGImage]?
    /// Per-house cached unit sprite atlas, keyed by houseID. Same
    /// sprite-index layout as `UnitSpriteAtlas` — see its doc for
    /// the global-index → source-SHP mapping.
    private var unitAtlasCache: [UInt8: [CGImage?]] = [:]

    public init(loader: AssetLoader) {
        self.loader = loader
    }

    public func render(
        runtime: ScenarioRuntime,
        originTileX: Int, originTileY: Int,
        widthTiles: Int, heightTiles: Int
    ) throws -> CGImage {
        guard widthTiles > 0, heightTiles > 0 else {
            throw Error.invalidRect
        }
        let tilePx = Self.tilePixels
        let w = widthTiles * tilePx
        let h = heightTiles * tilePx
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = buffer.withUnsafeMutableBytes({ ptr -> CGContext? in
            CGContext(
                data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: cs, bitmapInfo: info
            )
        }) else { throw Error.contextCreationFailed }
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)

        // 1. Ground tiles.
        let icnTiles = try loadIcnCached()
        let tiles = runtime.tileGrid
        for dy in 0..<heightTiles {
            for dx in 0..<widthTiles {
                let gx = originTileX + dx
                let gy = originTileY + dy
                guard (0..<64).contains(gx), (0..<64).contains(gy) else { continue }
                let tileIdx = gy * 64 + gx
                guard tileIdx < tiles.count else { continue }
                let tileID = Int(tiles[tileIdx].groundTileID)
                guard tileID >= 0, tileID < icnTiles.count else { continue }
                ctx.draw(icnTiles[tileID], in: tileRect(dx: dx, dy: dy, heightTiles: heightTiles))
            }
        }

        guard let host = runtime.host else {
            // Empty runtime — terrain-only render is valid.
            return try finishImage(ctx: ctx)
        }

        // 2. Structure house-colour outlines (behind units so any
        // overlap shows the unit on top, matching scene z-order).
        for idx in host.structures.findArray {
            let s = host.structures.slots[idx]
            guard s.isUsed, idx < Simulation.StructurePool.capacitySoft else { continue }
            let dims = Simulation.StructureInfo.lookup(s.type)?.layout.dimensions ?? (1, 1)
            let ax = Int(s.positionX) / 256
            let ay = Int(s.positionY) / 256
            // Footprint top-left tile in our output coords.
            let ox = ax - originTileX
            let oy = ay - originTileY
            // Rejection: outside the captured rect.
            if ox + dims.0 <= 0 || oy + dims.1 <= 0 { continue }
            if ox >= widthTiles || oy >= heightTiles { continue }

            let rect = footprintRect(
                tileX: ox, tileY: oy,
                wTiles: dims.0, hTiles: dims.1,
                heightTiles: heightTiles
            )
            let color = houseColor(for: s.houseID).cgColor
            ctx.setStrokeColor(color)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }

        // 3. Units. Same atlas logic as the scene — resolveFrame +
        // per-house palette remap via `UnitSpriteAtlas` source SHPs.
        for idx in host.units.findArray {
            let u = host.units.slots[idx]
            guard u.isUsed else { continue }
            // Skip projectiles — too ephemeral to stabilise a golden.
            if Simulation.Scheduler.isProjectileType(u.type) { continue }
            guard let unitInfo = Simulation.UnitInfo.lookup(u.type) else { continue }
            let tx = CGFloat(u.positionX) / 256
            let ty = CGFloat(u.positionY) / 256
            let cx = tx - CGFloat(originTileX)
            let cy = ty - CGFloat(originTileY)
            if cx < -1 || cy < -1 || cx > CGFloat(widthTiles) + 1 || cy > CGFloat(heightTiles) + 1 {
                continue
            }
            let frame = UnitSpriteAtlas.resolveFrame(
                info: unitInfo,
                orientation: u.orientationCurrent,
                spriteOffset: u.spriteOffset
            )
            guard let sprite = unitSprite(spriteID: frame.spriteID, houseID: u.houseID)
            else { continue }
            // Scale the sprite so its longest side = tilePx (matches
            // scene's max-dim scaling).
            let spriteW = sprite.width
            let spriteH = sprite.height
            let maxDim = max(spriteW, spriteH)
            guard maxDim > 0 else { continue }
            let scale = CGFloat(tilePx) / CGFloat(maxDim)
            let drawW = CGFloat(spriteW) * scale
            let drawH = CGFloat(spriteH) * scale
            // Destination rect: centred at unit position, flipped Y.
            let pxX = cx * CGFloat(tilePx) - drawW / 2
            let pxY = (CGFloat(heightTiles) - cy) * CGFloat(tilePx) - drawH / 2
            let dst = CGRect(x: pxX, y: pxY, width: drawW, height: drawH)
            ctx.saveGState()
            if frame.flipHorizontal {
                // Mirror horizontally around the unit's centre.
                ctx.translateBy(x: pxX + drawW / 2, y: pxY + drawH / 2)
                ctx.scaleBy(x: -1, y: 1)
                ctx.translateBy(x: -(pxX + drawW / 2), y: -(pxY + drawH / 2))
            }
            ctx.draw(sprite, in: dst)
            ctx.restoreGState()
        }

        // 4. Selection halo — one of (unit halo, structure halo). Mutually
        // exclusive in the runtime (see `ScenarioRuntime.leftClick`).
        if let sel = runtime.commandController.selectedUnitIndex,
           sel < host.units.slots.count, host.units.slots[sel].isUsed
        {
            let u = host.units.slots[sel]
            let tx = CGFloat(u.positionX) / 256
            let ty = CGFloat(u.positionY) / 256
            let cx = tx - CGFloat(originTileX)
            let cy = ty - CGFloat(originTileY)
            let centerX = cx * CGFloat(tilePx)
            let centerY = (CGFloat(heightTiles) - cy) * CGFloat(tilePx)
            let radius: CGFloat = CGFloat(tilePx) * 0.75
            let haloColor = runtime.commandController.isFriendlySelection
                ? CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
                : CGColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 1)
            ctx.setStrokeColor(haloColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(
                x: centerX - radius, y: centerY - radius,
                width: radius * 2, height: radius * 2
            ))
        } else if let sel = runtime.selectedStructureIndex,
                  sel < host.structures.slots.count,
                  host.structures.slots[sel].isUsed
        {
            let s = host.structures.slots[sel]
            let dims = Simulation.StructureInfo.lookup(s.type)?.layout.dimensions ?? (1, 1)
            let ax = Int(s.positionX) / 256
            let ay = Int(s.positionY) / 256
            let ox = ax - originTileX
            let oy = ay - originTileY
            let rect = footprintRect(
                tileX: ox, tileY: oy,
                wTiles: dims.0, hTiles: dims.1,
                heightTiles: heightTiles
            )
            let friendly = s.houseID == runtime.playerHouseID
            let haloColor = friendly
                ? CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
                : CGColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 1)
            ctx.setStrokeColor(haloColor)
            ctx.setLineWidth(2)
            ctx.stroke(rect.insetBy(dx: 1, dy: 1))
        }

        return try finishImage(ctx: ctx)
    }

    // MARK: Helpers

    private func tileRect(dx: Int, dy: Int, heightTiles: Int) -> CGRect {
        let tilePx = Self.tilePixels
        return CGRect(
            x: dx * tilePx,
            y: (heightTiles - 1 - dy) * tilePx,
            width: tilePx, height: tilePx
        )
    }

    private func footprintRect(
        tileX: Int, tileY: Int,
        wTiles: Int, hTiles: Int,
        heightTiles: Int
    ) -> CGRect {
        let tilePx = Self.tilePixels
        return CGRect(
            x: tileX * tilePx,
            y: (heightTiles - tileY - hTiles) * tilePx,
            width: wTiles * tilePx,
            height: hTiles * tilePx
        )
    }

    private func houseColor(for houseID: UInt8) -> NSColor {
        switch houseID {
        case 0: return HouseColors.color(for: .harkonnen)
        case 1: return HouseColors.color(for: .atreides)
        case 2: return HouseColors.color(for: .ordos)
        case 3: return HouseColors.color(for: .fremen)
        case 4: return HouseColors.color(for: .sardaukar)
        case 5: return HouseColors.color(for: .mercenary)
        default: return .white
        }
    }

    private func loadIcnCached() throws -> [CGImage] {
        if let cached = icnCache { return cached }
        let tiles = try loader.loadIcn()
        icnCache = tiles
        return tiles
    }

    private func unitSprite(spriteID: Int, houseID: UInt8) -> CGImage? {
        if unitAtlasCache[houseID] == nil {
            unitAtlasCache[houseID] = (try? Self.buildAtlas(loader: loader, houseID: houseID)) ??
                [CGImage?](repeating: nil, count: UnitSpriteAtlas.count)
        }
        guard let slots = unitAtlasCache[houseID],
              spriteID >= 0, spriteID < slots.count else { return nil }
        return slots[spriteID]
    }

    private static func buildAtlas(loader: AssetLoader, houseID: UInt8) throws -> [CGImage?] {
        var slots = [CGImage?](repeating: nil, count: UnitSpriteAtlas.count)
        try fill(into: &slots, at: 111, from: "UNITS2.SHP", houseID: houseID, loader: loader)
        try fill(into: &slots, at: 151, from: "UNITS1.SHP", houseID: houseID, loader: loader)
        try fill(into: &slots, at: 238, from: "UNITS.SHP",  houseID: houseID, loader: loader)
        return slots
    }

    private static func fill(
        into slots: inout [CGImage?], at baseID: Int,
        from shpName: String, houseID: UInt8, loader: AssetLoader
    ) throws {
        let frames = try loader.loadShp(named: shpName, houseID: houseID)
        for (i, cg) in frames.enumerated() {
            let slot = baseID + i
            guard slot < slots.count else { break }
            slots[slot] = cg
        }
    }

    private func finishImage(ctx: CGContext) throws -> CGImage {
        guard let image = ctx.makeImage() else {
            throw Error.contextCreationFailed
        }
        return image
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case invalidRect
        case contextCreationFailed
        public var description: String {
            switch self {
            case .invalidRect: return "width and height must be positive"
            case .contextCreationFailed: return "CGContext creation failed"
            }
        }
    }
}

public extension ScreenshotRenderer {
    /// Convenience: render + encode as PNG in-memory.
    func renderPNGData(
        runtime: ScenarioRuntime,
        originTileX: Int, originTileY: Int,
        widthTiles: Int, heightTiles: Int
    ) throws -> Data {
        let image = try render(
            runtime: runtime,
            originTileX: originTileX, originTileY: originTileY,
            widthTiles: widthTiles, heightTiles: heightTiles
        )
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.png" as CFString, 1, nil
        ) else { throw Error.contextCreationFailed }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw Error.contextCreationFailed
        }
        return data as Data
    }
}
