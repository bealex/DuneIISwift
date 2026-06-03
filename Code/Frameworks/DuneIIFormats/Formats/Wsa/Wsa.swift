import Foundation

/// Decoder for WSA animations. Ported from `WSA_LoadFile` / `WSA_GotoNextFrame`
/// (OpenDUNE `src/wsa.c:194,124`).
///
/// Header (10 bytes): frame count, width, height, required-buffer size, has-palette; then a frame
/// offset table of `frames + 2` little-endian uint32 entries. The table offsets exclude the optional
/// 0x300 embedded palette (it is added back when seeking to frame data). Each frame's chunk is
/// Format80-compressed; decoding it yields a Format40 XOR delta that is applied onto the running
/// frame buffer (frame 0 XORs onto a zero buffer, building the first image). See
/// `Documentation/Formats/Wsa.md`.
public enum Wsa {
    public enum DecodeError: Error, Equatable {
        case truncated
    }

    public struct Animation {
        public let width: Int
        public let height: Int
        public let palette: Palette?
        /// One entry per frame, each `width * height` 8-bit palette indices, row-major.
        public let frames: [[UInt8]]

        public init(_ data: Data) throws {
            let bytes = [ UInt8 ](data)
            guard bytes.count >= 18 else { throw DecodeError.truncated }

            let rawFrames = bytes.u16LE(at: 0)
            let width = bytes.u16LE(at: 2)
            let height = bytes.u16LE(at: 4)
            var hasPalette = bytes.u16LE(at: 8) != 0

            var lengthHeader = 10
            let standardOffset = 10 + 8 + 4 * rawFrames
            if bytes.u32LE(at: 10) != standardOffset && bytes.u32LE(at: 14) != standardOffset {
                // Old Dune v1.0 format: 8-byte header, no palette.
                lengthHeader = 8
                hasPalette = false
            }

            let frameCount = rawFrames & 0x7FFF
            let lengthPalette = hasPalette ? 0x300 : 0

            func frameOffset(_ index: Int) throws -> Int {
                let at = lengthHeader + index * 4
                guard at + 4 <= bytes.count else { throw DecodeError.truncated }

                return bytes.u32LE(at: at)
            }

            var palette: Palette?
            if hasPalette {
                let paletteStart = lengthHeader + (frameCount + 2) * 4
                if paletteStart + 0x300 <= bytes.count {
                    palette = try? Palette(Data(bytes[paletteStart ..< paletteStart + 0x300]))
                }
            }

            let frameSize = width * height
            var current = [ UInt8 ](repeating: 0, count: frameSize)
            var frames: [[UInt8]] = []
            frames.reserveCapacity(frameCount)
            for index in 0 ..< frameCount {
                let rawStart = try frameOffset(index)
                let rawEnd = try frameOffset(index + 1)
                if rawStart == 0 {
                    // Continuation WSA: no first frame stored here.
                    frames.append(current)
                    continue
                }

                let start = rawStart + lengthPalette
                let end = rawEnd + lengthPalette
                guard start <= end, end <= bytes.count else { throw DecodeError.truncated }

                let delta = try Format80.decodeToEnd(Data(bytes[start ..< end]))
                try Format40.decodeXOR(into: &current, source: delta)
                frames.append(current)
            }

            self.width = width
            self.height = height
            self.palette = palette
            self.frames = frames
        }
    }
}
