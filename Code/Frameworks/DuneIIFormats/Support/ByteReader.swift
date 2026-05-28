import Foundation

/// Little-/big-endian scalar reads over a 0-based byte array. Decoders convert their input `Data`
/// to `[UInt8]` first (so indices are always 0-based — `Data` slices are not) and guard the needed
/// length before calling these. Unchecked by design: the caller owns bounds.
extension Array where Element == UInt8 {
    func u16LE(at offset: Int) -> Int { Int(self[offset]) | (Int(self[offset + 1]) << 8) }

    func u16BE(at offset: Int) -> Int { (Int(self[offset]) << 8) | Int(self[offset + 1]) }

    func u32LE(at offset: Int) -> Int {
        Int(self[offset]) | (Int(self[offset + 1]) << 8) | (Int(self[offset + 2]) << 16) | (Int(self[offset + 3]) << 24)
    }

    func u32BE(at offset: Int) -> Int {
        (Int(self[offset]) << 24) | (Int(self[offset + 1]) << 16) | (Int(self[offset + 2]) << 8) | Int(self[offset + 3])
    }

    func fourCC(at offset: Int) -> String {
        String(bytes: self[offset ..< offset + 4], encoding: .ascii) ?? ""
    }
}
