import Foundation

/// Our native save format: a versioned binary encoding of the **whole** `GameState` — the pools
/// (units/structures/houses/teams + their find arrays), the map, both RNGs' internal state, the two clocks,
/// every tick cursor, the scenario, the in-progress animations/explosions, …. Because it captures every
/// mutable field (the RNG states included), `load(save(state))` resumes **bit-identically**: continuing the
/// loaded game produces the same run as if it had never been saved, so determinism is preserved — unlike a
/// converted *original* save, which resumes only behaviorally-faithfully (`SaveConverter`).
///
/// Encoded with a binary property list (Foundation-only, deterministic) behind a 5-byte magic + version
/// header. Bump `version` on any incompatible `GameState`-shape change. See `Documentation/Formats/Save.md`.
public enum SaveGame {
    static let magic: [UInt8] = [0x44, 0x55, 0x32, 0x53]   // "DU2S"
    static let version: UInt8 = 1

    public enum SaveError: Error, Equatable { case badMagic, badVersion(UInt8), truncated, decode }

    /// Encode `state` to our save bytes.
    public static func save(_ state: GameState) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        var data = Data(magic)
        data.append(version)
        data.append(try encoder.encode(state))
        return data
    }

    /// Decode a `GameState` from our save bytes. Throws on a wrong magic / unsupported version / corrupt body.
    public static func load(_ data: Data) throws -> GameState {
        guard data.count >= magic.count + 1 else { throw SaveError.truncated }
        guard Array(data.prefix(magic.count)) == magic else { throw SaveError.badMagic }
        let versionByte = data[data.startIndex + magic.count]
        guard versionByte == version else { throw SaveError.badVersion(versionByte) }
        let body = Data(data.suffix(from: data.startIndex + magic.count + 1))
        do { return try PropertyListDecoder().decode(GameState.self, from: body) }
        catch { throw SaveError.decode }
    }
}
