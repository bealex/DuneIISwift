/// Resolves an OpenDUNE voice id (a `SoundEvent`'s `SoundID`) to an effect VOC filename, via the ported
/// `g_table_voiceMapping` → `g_table_voices` (`src/table/sound.c`): `voiceID → voice index → "+NAME.VOC"`.
/// This first pass covers the combat **sound effects** (the `+` entries — gun/cannon/rocket/explosions);
/// the per-house spoken `%c` voices (announcements) are a follow-up that needs the house-letter prefix.
enum VoiceTable {
    /// voiceID → `g_table_voices` index (the non-`0xFFFF` combat-relevant entries).
    static let mapping: [Int: Int] = [
        24: 121, 39: 12, 40: 1, 41: 7, 42: 2,      // carryall-drop + weapon/effect cues
        44: 5, 49: 7, 50: 6, 51: 8, 54: 122,        // CRUMBLE (structure collapse) + explosion voices + EXTINY (mini-rocket)
        56: 9, 57: 9, 58: 11, 59: 10, 63: 26,       // bulletSounds: cannon / gun / gun-multi / worm
    ]
    /// `g_table_voices` index → effect VOC filename (the `+`/`-`/`/` entries, prefix stripped).
    static let voc: [Int: String] = [
        1: "EXSAND.VOC", 2: "ROCKET.VOC", 5: "CRUMBLE.VOC", 6: "EXSMALL.VOC", 7: "EXMED.VOC", 8: "EXLARGE.VOC",
        9: "EXCANNON.VOC", 10: "GUNMULTI.VOC", 11: "GUN.VOC", 12: "EXGAS.VOC", 26: "WORMET3P.VOC",
        121: "DROPEQ2P.VOC", 122: "EXTINY.VOC",
    ]

    static func vocName(forVoiceID id: Int) -> String? { mapping[id].flatMap { voc[$0] } }

    /// The distinct (voiceID, VOC) pairs the host preloads + registers under `SoundID(voiceID)`.
    static var registrations: [(voiceID: Int, voc: String)] {
        mapping.keys.sorted().compactMap { id in vocName(forVoiceID: id).map { (id, $0) } }
    }
}
