import DuneIIContracts

/// The spoken **"unit destroyed" announcement** (`Sound_Output_Feedback` death cues, `unit.c:1558`). Each
/// death feedback index the sim raises (`GameState.pendingFeedback`) maps to a *sequence* of `%c`-prefixed
/// voice fragments (`g_table_voices`), `%c` = the player house letter — e.g. "<house>ENEMY" + "<house>UNIT"
/// + "<house>DESTROY" → "enemy unit destroyed". A faithful port of the relevant `g_feedback[].voiceId[]`
/// (`src/table/sound.c`) + `g_table_voices[].string`. The host registers each fragment under
/// `FeedbackVoice.id(voiceIndex)` and plays the sequence in order (scheduled by each clip's duration).
enum FeedbackVoice {
    /// SoundID for a `g_table_voices` fragment index — a band kept above the unit-ack / announcement ids.
    static func id(_ voiceIndex: Int) -> SoundID { SoundID(2000 + voiceIndex) }

    /// The voice fragments to register: `g_table_voices` index → its VOC template (`%c` = the house prefix,
    /// substituted at registration). Only the fragments the death sequences below reference.
    static let fragments: [(voice: Int, template: String)] = [
        (29, "%cENEMY.VOC"), (30, "%cHARK.VOC"), (31, "%cATRE.VOC"), (32, "%cORDOS.VOC"),
        (33, "%cFREMEN.VOC"), (34, "%cSARD.VOC"), (36, "%cUNIT.VOC"), (50, "%cSABOT.VOC"), (53, "%cDESTROY.VOC"),
    ]

    /// Death feedback index → the fragment sequence (`g_table_voices` indices), from `g_feedback`:
    /// 13 = "enemy unit destroyed"; 14-18 = "<house> unit destroyed" (Harkonnen/Atreides/Ordos/Fremen/
    /// Sardaukar, = `houseID + 14`); 20 = "saboteur destroyed". (Mercenary's 19 → unprefixed FILLER is
    /// skipped — a graceful silent no-op for that rare case.)
    static let deathSequences: [UInt16: [Int]] = [
        13: [29, 36, 53], 14: [30, 36, 53], 15: [31, 36, 53], 16: [32, 36, 53],
        17: [33, 36, 53], 18: [34, 36, 53], 20: [50, 53],
    ]
}
