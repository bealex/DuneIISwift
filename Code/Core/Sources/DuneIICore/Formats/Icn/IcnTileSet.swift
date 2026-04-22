import Foundation

extension Formats {
    public enum Icn {
        /// ICN is an IFF `FORM` container holding 4-bit-packed terrain tiles
        /// (normally 16×16). Each tile carries a 1-byte index into a palette
        /// table (`RPAL`); each palette entry is 16 indices into the full
        /// 256-entry PAL, so tiles only consume 16 colors at a time.
        ///
        /// Reference: OpenDUNE `src/sprites.c` · `Tiles_LoadICNFile`.
        /// Chunk tags: `SINF` (info), `SSET` (pixels), `RTBL` (tile→palette
        /// map), `RPAL` (palette table).
        public struct TileSet: Sendable {
            public let tileWidth: Int     // pixels, usually 16
            public let tileHeight: Int    // pixels, usually 16
            public let tileCount: Int
            /// `RPAL` — one 16-byte entry per palette. A tile's final pixel is
            /// `rpal[ rtbl[tile] * 16 + nibble ]`, which yields a 256-color
            /// PAL index.
            public let rpal: [UInt8]
            /// `RTBL` — one byte per tile, index into `rpal`.
            public let rtbl: [UInt8]

            /// Expanded 8-bit palette indices for a given tile, row-major
            /// (`tileWidth * tileHeight` entries).
            public func pixels(forTile tileIndex: Int) -> [UInt8] {
                pixels(forTile: tileIndex, houseID: 0)
            }

            /// Same as `pixels(forTile:)` but remaps the 16-entry per-tile
            /// sub-palette through `Palette.applyHouseColors` first, so
            /// pixel bytes in the `[0x90, 0x98]` house-colour band render
            /// using `houseID`'s band instead of Harkonnen's. HouseID 0
            /// is the identity (matches Harkonnen's default colours).
            /// Used by structure rendering — OpenDUNE applies the same
            /// remap on the fly via `GUI_Widget_Viewport_GetSprite_HousePalette`.
            public func pixels(forTile tileIndex: Int, houseID: UInt8) -> [UInt8] {
                precondition(tileIndex < tileCount, "tile index out of range")
                let paletteBase = Int(rtbl[tileIndex]) * 16
                var subPalette = Array(rpal[paletteBase..<(paletteBase + 16)])
                // OpenDUNE's `GFX_DrawTile` (`src/gfx.c:210`) uses the
                // wider band `(colour & 0xF0) == 0x90` — the full
                // 0x90..0x9F range — for map-tile house remap. The
                // enhanced-mode narrower rule (`colour <= 0x96`) is a
                // port-only ENHANCEMENT; vanilla D2 remaps the whole
                // upper half too. Units go through the narrower
                // sprite-palette range via `applyHouseColors`.
                if houseID != 0 {
                    for i in 0..<16 {
                        let v = subPalette[i]
                        if (v & 0xF0) == 0x90 {
                            subPalette[i] = v &+ (houseID &<< 4)
                        }
                    }
                }
                let tileByteSize = (tileWidth * tileHeight) / 2
                let start = tileIndex * tileByteSize
                var out: [UInt8] = []
                out.reserveCapacity(tileWidth * tileHeight)
                for i in 0..<tileByteSize {
                    let byte = packedPixels[start + i]
                    // Upper nibble is the left pixel.
                    out.append(subPalette[Int(byte >> 4)])
                    out.append(subPalette[Int(byte & 0x0F)])
                }
                return out
            }

            let packedPixels: [UInt8]
        }

        public enum DecodeError: Error, Equatable, Sendable {
            case notFormForm
            case missingChunk(String)
            case unsupportedSpriteSetCompression(UInt8)
            case tileSizeUnsupported(widthSize: Int, heightSize: Int)
        }

        public static func decode(_ data: Data) throws -> TileSet {
            guard data.count >= 12 else { throw DecodeError.notFormForm }
            let base = data.startIndex
            guard readFourCC(data, at: base) == "FORM" else { throw DecodeError.notFormForm }
            // Skip size (4 bytes) + outer form tag (4 bytes) — total 12 bytes
            // from start. The outer tag is something like "ICON" but OpenDUNE
            // does not check it.

            let chunks = try readChunks(data)
            guard let sinf = chunks["SINF"] else { throw DecodeError.missingChunk("SINF") }
            guard let sset = chunks["SSET"] else { throw DecodeError.missingChunk("SSET") }
            guard let rtbl = chunks["RTBL"] else { throw DecodeError.missingChunk("RTBL") }
            guard let rpal = chunks["RPAL"] else { throw DecodeError.missingChunk("RPAL") }

            // SINF: [widthSize, heightSize, tileCountLow, tileCountHigh].
            guard sinf.count >= 4 else { throw DecodeError.missingChunk("SINF") }
            let widthSize = Int(sinf[sinf.startIndex + 0])
            let heightSize = Int(sinf[sinf.startIndex + 1])
            // tileCount is also carried in SINF[2..3] for some files, but the
            // authoritative count is RTBL.count — OpenDUNE trusts that too.
            guard widthSize == heightSize, widthSize < 3 else {
                throw DecodeError.tileSizeUnsupported(widthSize: widthSize, heightSize: heightSize)
            }
            let tileWidthBytes = widthSize << 2   // 8 bytes for widthSize=2
            let tileHeight = heightSize << 3      // 16 rows for heightSize=2
            let tileByteSize = tileWidthBytes * tileHeight  // 128 bytes for 16×16
            let tileWidthPixels = tileWidthBytes * 2

            // SSET starts with a 1-byte compression tag then a header slice
            // identical to CPS (see Sprites_Decode in sprites.c).
            let packed = try decodeSpriteSet(sset)
            let tileCount = packed.count / tileByteSize

            return TileSet(
                tileWidth: tileWidthPixels,
                tileHeight: tileHeight,
                tileCount: tileCount,
                rpal: Array(rpal),
                rtbl: Array(rtbl),
                packedPixels: packed
            )
        }

        private static func decodeSpriteSet(_ chunk: Data) throws -> [UInt8] {
            guard !chunk.isEmpty else { return [] }
            let tag = chunk[chunk.startIndex]
            switch tag {
            case 0x00:
                // Uncompressed. Layout mirrors CPS: tag, pad, u32 decoded size,
                // u16 palette size, payload.
                guard chunk.count >= 8 else { throw DecodeError.unsupportedSpriteSetCompression(tag) }
                let size = Int(readU32LE(chunk, at: chunk.startIndex + 2))
                let paletteSize = Int(readU16LE(chunk, at: chunk.startIndex + 6))
                let start = chunk.startIndex + 8 + paletteSize
                return Array(chunk[start..<(start + size)])
            case 0x04:
                // Format80-compressed.
                guard chunk.count >= 8 else { throw DecodeError.unsupportedSpriteSetCompression(tag) }
                let paletteSize = Int(readU16LE(chunk, at: chunk.startIndex + 6))
                let start = chunk.startIndex + 8 + paletteSize
                let payload = chunk.subdata(in: start..<chunk.endIndex)
                // OpenDUNE uses 0xFFFF as a generous upper bound — we don't
                // know the decoded size for sure, so match that.
                let decoded = try Codec.Format80.decode(payload, destinationCapacity: 0xFFFF)
                return Array(decoded)
            default:
                throw DecodeError.unsupportedSpriteSetCompression(tag)
            }
        }

        private static func readChunks(_ data: Data) throws -> [String: Data] {
            var chunks: [String: Data] = [:]
            var cursor = data.startIndex + 12 // past FORM + size + outer tag
            while cursor + 8 <= data.endIndex {
                let tag = readFourCC(data, at: cursor)
                // Chunk length is big-endian.
                let length = Int(readU32BE(data, at: cursor + 4))
                let dataStart = cursor + 8
                let dataEnd = dataStart + length
                guard dataEnd <= data.endIndex else { break }
                chunks[tag] = data.subdata(in: dataStart..<dataEnd)
                // Chunks are padded to even size.
                cursor = dataEnd + (length & 1)
            }
            return chunks
        }

        private static func readFourCC(_ data: Data, at offset: Int) -> String {
            let bytes = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
            return String(bytes: bytes, encoding: .ascii) ?? ""
        }

        private static func readU16LE(_ data: Data, at offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }

        private static func readU32LE(_ data: Data, at offset: Int) -> UInt32 {
            UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }

        private static func readU32BE(_ data: Data, at offset: Int) -> UInt32 {
            (UInt32(data[offset]) << 24)
                | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8)
                | UInt32(data[offset + 3])
        }
    }
}
