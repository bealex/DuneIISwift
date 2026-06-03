import Foundation

/// Decoder for ICN tile sets (`ICON.ICN` — the terrain/structure map tiles). Ported from
/// `Tiles_LoadICNFile` (OpenDUNE `src/sprites.c:220`) + `GFX_DrawTile` (`src/gfx.c:210`).
///
/// An ICN is an IFF/FORM container with chunks: `SINF` (tile geometry codes), `SSET` (4-bit packed
/// tile pixels, image-block compressed), `RTBL` (per-tile palette index), and `RPAL` (a flat array of
/// 16-byte palettes). A tile's pixels are 4-bit indices into its 16-entry palette (`RPAL` slice
/// chosen by `RTBL[tile]`), each mapping to an 8-bit main-palette index. High nibble is the left
/// pixel, low nibble the right. See `Documentation/Formats/Icn.md`.
public enum Icn {
    public enum DecodeError: Error, Equatable {
        case missingChunk
        case truncated
    }

    public struct TileSet {
        public let tileWidth: Int
        public let tileHeight: Int
        public let tileCount: Int

        private let pixels4bpp: [UInt8]
        private let bytesPerTile: Int
        private let rtbl: [UInt8]
        private let rpal: [UInt8]

        public init(_ data: Data) throws {
            let reader = try Iff.Reader(data)
            guard
                let sinf = reader.chunk("SINF"),
                sinf.count >= 2,
                let sset = reader.chunk("SSET"),
                let table = reader.chunk("RTBL"),
                let palettes = reader.chunk("RPAL")
            else { throw DecodeError.missingChunk }

            let info = [UInt8](sinf)
            let bytesPerRow = Int(info[0]) << 2
            let height = Int(info[1]) << 3
            let bytesPerTile = bytesPerRow * height
            let pixels = try ImageBlock.decode([UInt8](sset))

            self.tileWidth = bytesPerRow * 2
            self.tileHeight = height
            self.bytesPerTile = bytesPerTile
            self.pixels4bpp = pixels
            self.rtbl = [UInt8](table)
            self.rpal = [UInt8](palettes)
            self.tileCount = bytesPerTile > 0 ? pixels.count / bytesPerTile : 0
        }

        /// Tile `index` decoded to `tileWidth * tileHeight` 8-bit main-palette indices, row-major.
        public func tile(_ index: Int) -> [UInt8] {
            guard index >= 0, index < tileCount, index < rtbl.count else { return [] }

            let paletteBase = Int(rtbl[index]) << 4
            let start = index * bytesPerTile
            var pixels: [UInt8] = []
            pixels.reserveCapacity(tileWidth * tileHeight)
            for byte in pixels4bpp[start ..< start + bytesPerTile] {
                let left = paletteBase + Int(byte >> 4)
                let right = paletteBase + Int(byte & 0x0F)
                pixels.append(left < rpal.count ? rpal[left] : 0)
                pixels.append(right < rpal.count ? rpal[right] : 0)
            }
            return pixels
        }
    }
}
