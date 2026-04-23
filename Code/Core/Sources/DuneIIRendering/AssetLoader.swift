import Foundation
import CoreGraphics
import DuneIICore
import AssetExport

/// High-level, install-rooted asset access for the runtime. Caches the
/// default palette (`IBM.PAL`) and decoded `IconMap` / `TileResolver`
/// because everything downstream needs them. Not thread-safe — intended
/// to live on the main actor and be touched only from scene setup.
public final class AssetLoader {
    public let installation: Installation
    public private(set) var palette: Formats.Palette
    public private(set) var iconMap: Formats.IconMap
    public private(set) var tileResolver: TileResolver

    public enum LoadError: Error, Sendable {
        case missingPalette
        case missingIconMap
        case missingAsset(String)
        case decodeFailed(name: String, cause: String)
    }

    public init(installation: Installation) throws {
        self.installation = installation
        guard let palBody = installation.body(of: "IBM.PAL") else {
            throw LoadError.missingPalette
        }
        guard let rawPalette = try? Formats.Palette(data: palBody) else {
            throw LoadError.decodeFailed(name: "IBM.PAL", cause: "palette decoder threw")
        }
        // OpenDUNE's `GUI_PaletteAnimate` shifts palette index 223
        // between colours 12 and 10 every 5 ticks for the "windtrap
        // vanes" effect. We don't run that animation yet (would need
        // to invalidate every cached ICN / SHP tile on each shift);
        // instead, statically resolve index 223 to colour 12 at load
        // time so structures render in a legible hue rather than hot
        // pink. See `Formats.Palette.overridingIndex(_:with:)`.
        self.palette = rawPalette.overridingIndex(223, with: 12)

        guard let mapBody = installation.body(of: "ICON.MAP") else {
            throw LoadError.missingIconMap
        }
        guard let map = try? Formats.IconMap.decode(mapBody) else {
            throw LoadError.decodeFailed(name: "ICON.MAP", cause: "iconmap decoder threw")
        }
        self.iconMap = map
        self.tileResolver = TileResolver(iconMap: map)
    }

    // MARK: High-level loaders

    /// Decodes a named CPS to a `CGImage`. When the CPS embeds its own
    /// partial palette, use it; otherwise fall back to the installation's
    /// default `IBM.PAL`.
    public func loadCps(named name: String) throws -> CGImage {
        guard let body = installation.body(of: name) else {
            throw LoadError.missingAsset(name)
        }
        let cps: Formats.Cps.Image
        do {
            cps = try Formats.Cps.decode(body)
        } catch {
            throw LoadError.decodeFailed(name: name, cause: "\(error)")
        }
        return try CGImageFactory.makeImage(
            indices: cps.pixels,
            width: Formats.Cps.Image.width,
            height: Formats.Cps.Image.height,
            palette: cps.palette ?? palette,
            mode: .opaque
        )
    }

    /// Decodes a named SHP and returns every frame as a separate `CGImage`.
    /// Transparent (index-0) pixels become alpha-0 so `SKSpriteNode` blends
    /// naturally over the background.
    ///
    /// When `houseID` is supplied, frames that carry an embedded
    /// mini-palette (`hasHousePalette`) are remapped via
    /// `Formats.Palette.applyHouseColors(_:houseID:)` so unit + structure
    /// sprites take on their owning house's colours. Frames without a
    /// mini-palette (bullets, shared SHPs) render through the default
    /// palette unchanged — which matches OpenDUNE's behaviour of
    /// `GUI_Widget_Viewport_GetSprite_HousePalette` returning `false` in
    /// that case.
    public func loadShp(named name: String, houseID: UInt8 = 0) throws -> [CGImage] {
        guard let body = installation.body(of: name) else {
            throw LoadError.missingAsset(name)
        }
        let shp: Formats.Shp.FrameSet
        do {
            shp = try Formats.Shp.decode(body)
        } catch {
            throw LoadError.decodeFailed(name: name, cause: "\(error)")
        }
        return try shp.frames.map { frame in
            if let sub = frame.housePalette {
                let remapped = Formats.Palette.applyHouseColors(sub, houseID: houseID)
                return try CGImageFactory.makeImage(
                    indices: frame.pixels, width: frame.width, height: frame.height,
                    subPalette: remapped, palette: palette, mode: .index0Transparent
                )
            }
            return try CGImageFactory.makeImage(
                indices: frame.pixels, width: frame.width, height: frame.height,
                palette: palette, mode: .index0Transparent
            )
        }
    }

    /// Raw ICN tile-set (packed pixels + rpal/rtbl). Exposed so callers
    /// that need per-tile per-house palette remap can render their own
    /// CGImages via `pixels(forTile:houseID:)`. See `ScreenshotRenderer`.
    public func loadIcnTileSet(named name: String = "ICON.ICN") throws -> Formats.Icn.TileSet {
        guard let body = installation.body(of: name) else {
            throw LoadError.missingAsset(name)
        }
        do {
            return try Formats.Icn.decode(body)
        } catch {
            throw LoadError.decodeFailed(name: name, cause: "\(error)")
        }
    }

    /// Decodes a named ICN and returns every tile as a separate `CGImage`.
    /// Returned in `TileSet.tiles` order — `TileResolver.tileId(_:offset:)`
    /// maps `(group, offset)` into this array.
    public func loadIcn(named name: String = "ICON.ICN") throws -> [CGImage] {
        guard let body = installation.body(of: name) else {
            throw LoadError.missingAsset(name)
        }
        let icn: Formats.Icn.TileSet
        do {
            icn = try Formats.Icn.decode(body)
        } catch {
            throw LoadError.decodeFailed(name: name, cause: "\(error)")
        }
        var images: [CGImage] = []
        images.reserveCapacity(icn.tileCount)
        for i in 0..<icn.tileCount {
            let pixels = icn.pixels(forTile: i)
            let image = try CGImageFactory.makeImage(
                indices: pixels, width: icn.tileWidth, height: icn.tileHeight,
                palette: palette, mode: .opaque
            )
            images.append(image)
        }
        return images
    }

    /// Reads a scenario INI body from the install. Returns nil when absent
    /// (e.g. the requested scenario number isn't installed for this house).
    public func loadScenario(named name: String) throws -> Scenario? {
        guard let body = installation.body(of: name) else { return nil }
        do {
            return try Scenario(iniData: body)
        } catch {
            throw LoadError.decodeFailed(name: name, cause: "\(error)")
        }
    }

    /// Reads a Dune II `.ENG` / `.FRE` / … string-table body from the
    /// install and decodes it. `compressed` must match OpenDUNE's
    /// `String_Init` — `TEXTH` / `TEXTA` / `TEXTO` / `PROTECT` are
    /// compressed, the rest are plain. Returns `nil` when absent so
    /// callers can degrade gracefully on a stripped install.
    public func loadStrings(named name: String, compressed: Bool) throws -> [String]? {
        guard let body = installation.body(of: name) else { return nil }
        do {
            return try Formats.Strings.decode(body, compressed: compressed)
        } catch {
            throw LoadError.decodeFailed(name: name, cause: "\(error)")
        }
    }

    /// Reads a compiled EMC script (`UNIT.EMC`, `BUILD.EMC`, `TEAM.EMC`)
    /// from the install. Returns nil when absent. Used by the simulation
    /// tick loop; see `ScenarioScene`.
    public func loadEmc(named name: String) throws -> Formats.Emc.Program? {
        guard let body = installation.body(of: name) else { return nil }
        do {
            return try Formats.Emc.Program.decode(body)
        } catch {
            throw LoadError.decodeFailed(name: name, cause: "\(error)")
        }
    }

    /// Decodes a WSA animation + renders every frame to a `CGImage`.
    /// Frames with `hasPalette == true` use the WSA's embedded palette;
    /// others fall back to `IBM.PAL`. Returns the ordered array of
    /// images (frame 0 first) alongside the native frame size so callers
    /// can size their `SKSpriteNode` correctly.
    public struct WsaFrames: Sendable {
        public let frames: [CGImage]
        public let width: Int
        public let height: Int
    }

    public func loadWsa(named name: String) throws -> WsaFrames {
        guard let body = installation.body(of: name) else {
            throw LoadError.missingAsset(name)
        }
        let wsa: Formats.Wsa.Animation
        do {
            wsa = try Formats.Wsa.decode(body)
        } catch {
            throw LoadError.decodeFailed(name: name, cause: "\(error)")
        }
        let pal = wsa.palette ?? palette
        var images: [CGImage] = []
        images.reserveCapacity(wsa.frames.count)
        for frame in wsa.frames {
            let img = try CGImageFactory.makeImage(
                indices: frame,
                width: wsa.width, height: wsa.height,
                palette: pal,
                mode: .opaque
            )
            images.append(img)
        }
        return WsaFrames(frames: images, width: wsa.width, height: wsa.height)
    }

    /// Decodes an XMI song from the install and returns the **first
    /// track** as a Standard MIDI File byte stream, ready to hand to
    /// `AVMIDIPlayer(data:soundBankURL:)`. Dune II's music files are
    /// multi-track catalogs (one track per in-game cue); the first
    /// track is the "play me" song for that file. Returns nil when the
    /// asset is absent.
    public func loadXmiAsSMF(named name: String) throws -> Data? {
        guard let body = installation.body(of: name) else { return nil }
        let song: Formats.Xmi.Song
        do {
            song = try Formats.Xmi.Song.decode(body)
        } catch {
            throw LoadError.decodeFailed(name: name, cause: "\(error)")
        }
        guard let first = song.tracks.first else { return nil }
        return first.toStandardMidiFile()
    }

    /// Decodes a VOC sample from the install. Returns nil when absent.
    public func loadVoc(named name: String) throws -> Formats.Voc.Sound? {
        guard let body = installation.body(of: name) else { return nil }
        do {
            return try Formats.Voc.decode(body)
        } catch {
            throw LoadError.decodeFailed(name: name, cause: "\(error)")
        }
    }
}
