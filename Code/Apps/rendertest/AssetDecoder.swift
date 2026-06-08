import CoreGraphics
import DuneIIFormats
import DuneIIRenderer
import Foundation

/// One decoded raster frame: palette indices + dimensions, plus whether it carries house-remap lookup pixels.
struct RawFrame {
    let indices: [UInt8]
    let width: Int
    let height: Int
    let hasLookup: Bool
}

/// How a frame's indices should be house-recoloured when rendered.
enum RemapKind {
    case none
    case sprite
    case tile
}

/// The product of decoding an asset for the inspector: the raster frames plus the metadata the detail view
/// needs to render and label them. Pure data — no SwiftUI, no view state — so the per-format decode and the
/// sheet/structure assembly live outside the view that displays it.
struct DecodedAsset {
    var rawFrames: [RawFrame] = []
    var displayPalette: Palette?
    var transparentIndex: Int?
    var remapKind: RemapKind = .none
    var paletteAnimatable = false
    var sound: Voc.Sound?
    var scriptText: String?
    var info = ""
    /// The frame to show first (e.g. a structure's completed state); 0 for everything else.
    var initialFrameIndex = 0
}

/// Decodes an `AssetLibrary.Asset` into a `DecodedAsset`. Holds the library for PAK data + palette lookups;
/// every per-format branch and the tile-sheet / structure assembly that used to live inside `AssetDetailView`
/// is here, so the view is left with only rendering (house remap + palette cycling) and presentation.
@MainActor
struct AssetDecoder {
    let library: AssetLibrary

    func decode(_ asset: AssetLibrary.Asset) -> DecodedAsset {
        var result = DecodedAsset()

        // Music tracks carry no PAK data — they're previewed from `asset.music` via the OPL3 player.
        if asset.kind == .music, let track = asset.music {
            result.info = "AdLib FM track · DUNE\(track.file).ADL · subsong \(track.song)"
            return result
        }

        guard
            let data = library.data(for: asset)
        else {
            result.info = "(asset data missing)"
            return result
        }

        switch asset.kind {
            case .sprite:
                guard
                    let set = try? Shp.FrameSet(data)
                else {
                    result.info = "(SHP decode failed)"
                    return result
                }

                let selected =
                    asset.frameRange.map { Array(set.frames[$0.clamped(to: set.frames.indices)]) } ?? set.frames
                result.rawFrames = selected.compactMap { frame in
                    frame.width > 0 && frame.height > 0
                        ? RawFrame(
                            indices: frame.pixels,
                            width: frame.width,
                            height: frame.height,
                            hasLookup: frame.hasLookup
                        )
                        : nil
                }
                result.transparentIndex = 0
                result.remapKind = .sprite
                result.displayPalette = contextPalette(for: asset.name)  // e.g. mercenary mentat face → BENE.PAL
                let kindLabel = asset.groupKind.map { $0 == .animation ? " · animation" : " · directional" } ?? ""
                result.info = "\(selected.count) frames\(kindLabel)"
            case .image:
                guard
                    let image = try? Cps.decode(data)
                else {
                    result.info = "(CPS decode failed)"
                    return result
                }

                result.rawFrames = [
                    RawFrame(indices: image.pixels, width: image.width, height: image.height, hasLookup: false)
                ]
                result.displayPalette = image.palette ?? contextPalette(for: asset.name)  // e.g. MENTATM.CPS → BENE.PAL
                result.info = "\(image.width)×\(image.height)"
            case .tiles:
                guard
                    let tiles = try? Icn.TileSet(data)
                else {
                    result.info = "(ICN decode failed)"
                    return result
                }

                let sheet = tileSheet(tiles)
                result.rawFrames = [
                    RawFrame(indices: sheet.indices, width: sheet.width, height: sheet.height, hasLookup: false)
                ]
                result.remapKind = .tile
                result.info = "\(tiles.tileCount) tiles · \(tiles.tileWidth)×\(tiles.tileHeight) (16 per row)"
            case .animation:
                guard
                    let animation = try? Wsa.Animation(data)
                else {
                    result.info = "(WSA decode failed)"
                    return result
                }

                result.rawFrames = animation.frames.map {
                    RawFrame(indices: $0, width: animation.width, height: animation.height, hasLookup: false)
                }
                result.displayPalette = animation.palette ?? contextPalette(for: asset.name)  // intro/finale → INTRO.PAL
                result.info = "\(animation.frames.count) frames · \(animation.width)×\(animation.height)"
            case .font:
                guard
                    let font = try? Fnt.Font(data)
                else {
                    result.info = "(FNT decode failed)"
                    return result
                }

                let sheet = fontSheet(font)
                result.rawFrames = [
                    RawFrame(indices: sheet.indices, width: sheet.width, height: sheet.height, hasLookup: false)
                ]
                result.displayPalette = Self.monochrome
                result.transparentIndex = 0
                result.info = "\(font.glyphs.count) glyphs · height \(font.height)"
            case .sound:
                result.sound = try? Voc.decode(data)
                result.info =
                    result.sound.map { "\($0.sampleRate) Hz · \($0.samples.count) samples" } ?? "(VOC decode failed)"
            case .music:
                break  // handled before the `guard let data` above (music has no PAK data)
            case .script:
                result.scriptText = (try? Emc.Program(data)).map { emcText($0, name: asset.name) }
                result.info = "EMC script"
            case .iconGroup:
                guard
                    let tiles = try? Icn.TileSet(data),
                    let mapData = library.data(pak: asset.pak, name: "ICON.MAP"),
                    let iconMap = try? IconMap(mapData),
                    let index = asset.iconGroup,
                    let group = iconMap.group(index)
                else {
                    result.info = "(icon group decode failed)"
                    return result
                }

                result.remapKind = .tile
                // A multi-tile structure: assemble each build/animation state into a whole building.
                if let layout = StructureCatalog.layout(iconGroup: index),
                        layout.width * layout.height > 1,
                        group.tileIDs.count % (layout.width * layout.height) == 0 {
                    result.rawFrames = assembleStructure(
                        tiles,
                        tileIDs: group.tileIDs,
                        width: layout.width,
                        height: layout.height
                    )
                    // Default to the completed building (state 2, per Structure_UpdateMap, structure.c:1779)
                    // rather than the foundation: its animated power light (palette index 223) lives here.
                    result.initialFrameIndex = min(2, max(result.rawFrames.count - 1, 0))
                    result.info =
                        "\(group.name) · \(layout.width)×\(layout.height) tiles · \(result.rawFrames.count) states"
                } else {
                    result.rawFrames = group.tileIDs.compactMap { tileID in
                        let pixels = tiles.tile(tileID)
                        return pixels.isEmpty
                            ? nil
                            : RawFrame(
                                indices: pixels,
                                width: tiles.tileWidth,
                                height: tiles.tileHeight,
                                hasLookup: false
                            )
                    }
                    result.info = "\(group.name) · \(result.rawFrames.count) tiles"
                }
        }

        // Palette cycling (GUI_PaletteAnimate, gui/gui.c:643) operates on the active game palette
        // (IBM.PAL), where indices 223/239/255 are magenta placeholders meant to be cycled. Content
        // that carries its own palette — CPS images, WSA animations, mentat-face SHPs — uses those
        // indices for real colors, so cycling there corrupts them. Only animate IBM.PAL-rendered
        // content, i.e. when no embedded/contextual palette was selected.
        result.paletteAnimatable = !result.rawFrames.isEmpty && result.displayPalette == nil
        return result
    }

    /// The palette for assets that carry none of their own (CPS/WSA with no embedded palette, SHP
    /// sprites). Most use the ambient game palette (IBM.PAL, the fallback); a few load a specific
    /// `.PAL` at runtime, which we reproduce here. Returns nil to mean "use the default IBM.PAL".
    ///
    /// - Mercenary mentat — `MENSHPM.SHP` (face) and `MENTATM.CPS` (portrait) draw under `BENE.PAL`
    ///   (OpenDUNE `gui/mentat.c:500`); the other houses' mentats use the ambient IBM.PAL. None of the
    ///   `MENTAT*.CPS` files embed a palette.
    /// - Cutscene animations — the intro (`INTRO*`) and per-house finale (`?FINAL*`) WSAs are played
    ///   under `INTRO.PAL`, loaded by `GameLoop_PrepareAnimation` (`cutscene.c:82`). They embed none.
    private func contextPalette(for name: String) -> Palette? {
        let upper = name.uppercased()
        if upper == "MENSHPM.SHP" || upper == "MENTATM.CPS" { return library.palette(named: "BENE.PAL") }

        let cutscenePrefixes = [ "INTRO", "AFINAL", "EFINAL", "HFINAL", "OFINAL" ]
        if upper.hasSuffix(".WSA"), cutscenePrefixes.contains(where: { upper.hasPrefix($0) }) {
            return library.palette(named: "INTRO.PAL")
        }
        return nil
    }

    /// Assemble a structure icon group's tiles into whole-building frames: the group's tiles are
    /// consecutive build/animation states of `width * height` tiles each (row-major), so each state
    /// becomes one `(width*16)×(height*16)` image. See `StructureCatalog`.
    private func assembleStructure(_ tiles: Icn.TileSet, tileIDs: [Int], width: Int, height: Int) -> [RawFrame] {
        let tileW = tiles.tileWidth
        let tileH = tiles.tileHeight
        let perState = width * height
        guard perState > 1, tileIDs.count >= perState else { return [] }

        let frameW = width * tileW
        let frameH = height * tileH
        var frames: [RawFrame] = []
        for state in 0 ..< (tileIDs.count / perState) {
            var indices = [UInt8](repeating: 0, count: frameW * frameH)
            for i in 0 ..< perState {
                let pixels = tiles.tile(tileIDs[state * perState + i])
                guard !pixels.isEmpty else { continue }

                let originX = (i % width) * tileW
                let originY = (i / width) * tileH
                for y in 0 ..< tileH {
                    for x in 0 ..< tileW {
                        let source = y * tileW + x
                        if source < pixels.count { indices[(originY + y) * frameW + originX + x] = pixels[source] }
                    }
                }
            }
            frames.append(RawFrame(indices: indices, width: frameW, height: frameH, hasLookup: false))
        }
        return frames
    }

    private func tileSheet(_ tiles: Icn.TileSet) -> (indices: [UInt8], width: Int, height: Int) {
        let perRow = 16
        let rows = max((tiles.tileCount + perRow - 1) / perRow, 1)
        let width = tiles.tileWidth * perRow
        let height = tiles.tileHeight * rows
        var indices = [UInt8](repeating: 0, count: width * height)
        for tile in 0 ..< tiles.tileCount {
            let pixels = tiles.tile(tile)
            let originX = (tile % perRow) * tiles.tileWidth
            let originY = (tile / perRow) * tiles.tileHeight
            for y in 0 ..< tiles.tileHeight {
                for x in 0 ..< tiles.tileWidth {
                    let source = y * tiles.tileWidth + x
                    if source < pixels.count { indices[(originY + y) * width + originX + x] = pixels[source] }
                }
            }
        }
        return (indices, width, height)
    }

    private func fontSheet(_ font: Fnt.Font) -> (indices: [UInt8], width: Int, height: Int) {
        let perRow = 16
        let cellWidth = max(font.maxWidth, 1)
        let cellHeight = max(font.height, 1)
        let rows = max((font.glyphs.count + perRow - 1) / perRow, 1)
        let width = cellWidth * perRow
        let height = cellHeight * rows
        var indices = [UInt8](repeating: 0, count: width * height)
        for (glyphIndex, glyph) in font.glyphs.enumerated() {
            let originX = (glyphIndex % perRow) * cellWidth
            let originY = (glyphIndex / perRow) * cellHeight + glyph.topRows
            for y in 0 ..< glyph.bitmapRows {
                for x in 0 ..< glyph.width {
                    let source = y * glyph.width + x
                    guard source < glyph.pixels.count, glyph.pixels[source] != 0 else { continue }

                    let px = originX + x
                    let py = originY + y
                    if px < width, py < height { indices[py * width + px] = 1 }  // set -> white
                }
            }
        }
        return (indices, width, height)
    }

    private func emcText(_ program: Emc.Program, name: String) -> String {
        let upper = name.uppercased()
        let kind: Emc.ObjectKind = upper.contains("BUILD") ? .structure : (upper.contains("TEAM") ? .team : .unit)
        var lines: [String] = []
        for typeIndex in program.offsets.indices {
            let instructions = Emc.disassemble(program, typeIndex: typeIndex, kind: kind)
            guard !instructions.isEmpty else { continue }

            lines.append("; ---- type \(typeIndex) ----")
            for instruction in instructions {
                var line = "\(instruction.address):  \(instruction.name)"
                if let operand = instruction.operand { line += " \(operand)" }
                if let functionName = instruction.functionName { line += "  ; \(functionName)" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A 2-entry palette (index 1 = white) for rendering font glyphs as white-on-transparent.
    static let monochrome: Palette = {
        var bytes = [UInt8](repeating: 0, count: 768)
        bytes[3] = 63
        bytes[4] = 63
        bytes[5] = 63
        return try! Palette(Data(bytes))
    }()
}
