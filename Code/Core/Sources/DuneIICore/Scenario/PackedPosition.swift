import Foundation

/// 16-bit position encoding used throughout Dune II's scenario INIs and
/// save files. The low 6 bits are the tile x-coordinate (0…63) and the
/// next 6 bits are y (0…63). The top 4 bits are unused on-disk (some
/// map-edge values have them set; OpenDUNE masks them off).
public struct PackedPosition: Sendable, Equatable, Hashable {
    public let raw: UInt16

    public init(raw: UInt16) {
        self.raw = raw
    }

    public init(x: UInt8, y: UInt8) {
        precondition(x < 64 && y < 64, "tile coords must be <64")
        self.raw = (UInt16(y) << 6) | UInt16(x)
    }

    public struct Tile: Sendable, Equatable, Hashable {
        public let x: UInt8
        public let y: UInt8
    }

    public var tile: Tile {
        Tile(x: UInt8(raw & 0x3F), y: UInt8((raw >> 6) & 0x3F))
    }
}
