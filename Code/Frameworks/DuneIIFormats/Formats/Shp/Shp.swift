import Foundation

/// Decoder for SHP sprite sets (units, structures, UI sprites). Ported from `Sprites_Load`
/// (OpenDUNE `src/sprites.c:60`) and the frame decode in `GUI_DrawSprite` (`src/gui/gui.c:1015`).
///
/// A SHP holds a frame count and an offset table (2-byte entries in the old Dune v1.0 format,
/// 4-byte in the v1.07 format — distinguished by whether `4 + count*4` equals the dword at offset 2;
/// new-format frame pointers are additionally `+2`). Each frame is a 10-byte header, an optional
/// 16-byte palette-lookup table, and a pixel payload that is Format80-compressed unless flag bit 1 is
/// set, then unpacked from a zero-run RLE. See `Documentation/Formats/Shp.md`.
public enum Shp {
    public enum DecodeError: Error, Equatable {
        case truncated
        case badFrame
    }

    public struct Frame: Equatable {
        public let width: Int
        public let height: Int
        /// Row-major 8-bit palette indices. Index 0 is transparent.
        public let pixels: [UInt8]
    }

    public struct FrameSet {
        public let frames: [Frame]

        public init(_ data: Data) throws {
            let bytes = [UInt8](data)
            guard bytes.count >= 6 else { throw DecodeError.truncated }

            let count = bytes.u16LE(at: 0)
            let oldFormat = (4 + count * 4) != bytes.u32LE(at: 2)

            var frames: [Frame] = []
            frames.reserveCapacity(count)
            for index in 0 ..< count {
                let offset: Int
                if oldFormat {
                    guard 2 + 2 * index + 2 <= bytes.count else { throw DecodeError.truncated }

                    offset = bytes.u16LE(at: 2 + 2 * index)
                } else {
                    guard 2 + 4 * index + 4 <= bytes.count else { throw DecodeError.truncated }

                    offset = bytes.u32LE(at: 2 + 4 * index)
                }

                if offset == 0 {
                    frames.append(Frame(width: 0, height: 0, pixels: []))
                    continue
                }

                frames.append(try Shp.decodeFrame(bytes, at: oldFormat ? offset : offset + 2))
            }
            self.frames = frames
        }
    }

    static func decodeFrame(_ bytes: [UInt8], at start: Int) throws -> Frame {
        guard start + 10 <= bytes.count else { throw DecodeError.truncated }

        let flags = bytes.u16LE(at: start)
        let height = Int(bytes[start + 2])
        let width = bytes.u16LE(at: start + 3)
        let decodedSize = bytes.u16LE(at: start + 8)

        var payload = start + 10
        var lookup: [UInt8]?
        if (flags & 0x1) != 0 {
            guard payload + 16 <= bytes.count else { throw DecodeError.truncated }

            lookup = Array(bytes[payload ..< payload + 16])
            payload += 16
        }

        let rle: [UInt8]
        if (flags & 0x2) != 0 {
            guard payload + decodedSize <= bytes.count else { throw DecodeError.truncated }

            rle = Array(bytes[payload ..< payload + decodedSize])
        } else {
            rle = [UInt8](try Format80.decode(Data(bytes[payload...]), destinationLength: decodedSize))
        }

        let pixelCount = width * height
        var pixels: [UInt8] = []
        pixels.reserveCapacity(pixelCount)
        var i = 0
        while pixels.count < pixelCount && i < rle.count {
            let value = rle[i]
            i += 1
            if value != 0 {
                if let lookup {
                    guard Int(value) < lookup.count else { throw DecodeError.badFrame }

                    pixels.append(lookup[Int(value)])
                } else {
                    pixels.append(value)
                }
            } else {
                guard i < rle.count else { break }

                let run = Int(rle[i])
                i += 1
                let end = min(pixels.count + run, pixelCount)
                while pixels.count < end { pixels.append(0) }
            }
        }
        while pixels.count < pixelCount { pixels.append(0) }

        return Frame(width: width, height: height, pixels: pixels)
    }
}
