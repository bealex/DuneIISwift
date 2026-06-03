import Foundation

/// A VGA palette: 256 colors with 6-bit components (0...63), as stored in `IBM.PAL` and embedded in
/// CPS/WSA files (256 RGB triples = 768 bytes). The 6-bit→8-bit display expansion matches OpenDUNE's
/// video driver exactly: `out8 = (value6 * 0x41) >> 4` (`src/video/video_sdl.c:722`). The raw 6-bit
/// values are the source of truth; expansion is a display concern. See `Documentation/Formats/Palette.md`.
public struct Palette: Equatable {
    public struct Color: Equatable {
        public var red: UInt8  // 0...63
        public var green: UInt8
        public var blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public enum DecodeError: Error, Equatable {
        case wrongSize
    }

    public static let colorCount = 256

    public let colors: [Color]

    /// Build a palette directly from 256 colors (used by palette-animation, which mutates entries).
    public init(colors: [Color]) {
        self.colors = colors
    }

    public init(_ data: Data) throws {
        guard data.count >= Palette.colorCount * 3 else { throw DecodeError.wrongSize }

        let bytes = [UInt8](data)
        var colors: [Color] = []
        colors.reserveCapacity(Palette.colorCount)
        for index in 0 ..< Palette.colorCount {
            let offset = index * 3
            colors.append(Color(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2]))
        }
        self.colors = colors
    }

    /// Expand a 6-bit VGA component (0...63) to 8 bits exactly as the original display path does.
    public static func expand6to8(_ value: UInt8) -> UInt8 {
        UInt8(((Int(value) & 0x3F) * 0x41) >> 4)
    }

    /// The color at `index`, expanded to 8-bit RGBA (opaque).
    public func rgba8(_ index: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let color = colors[index]
        return (Palette.expand6to8(color.red), Palette.expand6to8(color.green), Palette.expand6to8(color.blue), 255)
    }
}
