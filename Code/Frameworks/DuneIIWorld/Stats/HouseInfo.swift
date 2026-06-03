import DuneIIContracts

/// Per-house static stats. A literal port of OpenDUNE's `HouseInfo` struct (`src/house.h`) and the
/// `g_table_houseInfo[]` table (`src/table/houseinfo.c`). These are compile-time constants in the
/// original (hardcoded C, not loaded from disk), so they are `let`s here. Keyed by `HouseID`.
///
/// Verified field-for-field against an OpenDUNE golden dump — see `Documentation/Algorithms/StatTables.md`.
public struct HouseInfo: Sendable, Equatable {
    public let name: String
    public let toughness: UInt16  // deviation probability / retreat chance
    public let degradingChance: UInt16  // chance a created unit starts "degrading"
    public let degradingAmount: UInt16  // damage dealt to degrading structures
    public let minimapColor: UInt16
    public let specialCountDown: UInt16  // ticks between special-weapon activations
    public let starportDeliveryTime: UInt16
    public let prefixChar: UInt16  // filename prefix char, as its ASCII code (uint16 in C)
    public let specialWeapon: UInt16  // HouseWeapon
    public let musicWin: UInt16
    public let musicLose: UInt16
    public let musicBriefing: UInt16  // 0xFFFF = none
    public let voiceFilename: String

    /// Stats for `house`.
    public static subscript(_ house: HouseID) -> HouseInfo { table[house.rawValue] }

    /// `g_table_houseInfo[]`, indexed by `HouseID.rawValue`.
    public static let table: [HouseInfo] = [
        HouseInfo(
            name: "Harkonnen",
            toughness: 200,
            degradingChance: 85,
            degradingAmount: 3,
            minimapColor: 144,
            specialCountDown: 600,
            starportDeliveryTime: 10,
            prefixChar: ascii("H"),
            specialWeapon: 1,
            musicWin: 6,
            musicLose: 3,
            musicBriefing: 24,
            voiceFilename: "nhark.voc"
        ),
        HouseInfo(
            name: "Atreides",
            toughness: 77,
            degradingChance: 0,
            degradingAmount: 1,
            minimapColor: 160,
            specialCountDown: 300,
            starportDeliveryTime: 10,
            prefixChar: ascii("A"),
            specialWeapon: 2,
            musicWin: 7,
            musicLose: 4,
            musicBriefing: 25,
            voiceFilename: "nattr.voc"
        ),
        HouseInfo(
            name: "Ordos",
            toughness: 128,
            degradingChance: 10,
            degradingAmount: 2,
            minimapColor: 176,
            specialCountDown: 300,
            starportDeliveryTime: 10,
            prefixChar: ascii("O"),
            specialWeapon: 3,
            musicWin: 5,
            musicLose: 2,
            musicBriefing: 26,
            voiceFilename: "nordo.voc"
        ),
        HouseInfo(
            name: "Fremen",
            toughness: 10,
            degradingChance: 0,
            degradingAmount: 1,
            minimapColor: 192,
            specialCountDown: 300,
            starportDeliveryTime: 0,
            prefixChar: ascii("O"),
            specialWeapon: 2,
            musicWin: 5,
            musicLose: 2,
            musicBriefing: 65535,
            voiceFilename: "afremen.voc"
        ),
        HouseInfo(
            name: "Sardaukar",
            toughness: 10,
            degradingChance: 0,
            degradingAmount: 1,
            minimapColor: 208,
            specialCountDown: 600,
            starportDeliveryTime: 0,
            prefixChar: ascii("H"),
            specialWeapon: 1,
            musicWin: 6,
            musicLose: 3,
            musicBriefing: 65535,
            voiceFilename: "asard.voc"
        ),
        HouseInfo(
            name: "Mercenary",
            toughness: 0,
            degradingChance: 0,
            degradingAmount: 1,
            minimapColor: 224,
            specialCountDown: 300,
            starportDeliveryTime: 0,
            prefixChar: ascii("M"),
            specialWeapon: 3,
            musicWin: 7,
            musicLose: 4,
            musicBriefing: 65535,
            voiceFilename: "amerc.voc"
        ),
    ]
}

/// The ASCII code of a single-character string literal, for the `prefixChar` fields.
private func ascii(_ character: Character) -> UInt16 { UInt16(character.asciiValue!) }
