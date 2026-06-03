import DuneIIContracts

/// The spoken **feedback announcements** (`Sound_Output_Feedback`, `src/audio/sound.c`). Each feedback index
/// the sim raises (`GameState.pendingFeedback`) maps to a *sequence* of `%c`-prefixed voice fragments
/// (`g_table_voices`), `%c` = the player house letter — e.g. "<house>ENEMY" + "<house>UNIT" + "<house>DESTROY"
/// → "enemy unit destroyed". A faithful port of `g_feedback[].voiceId[]` (`src/table/sound.c`) +
/// `g_table_voices[].string` for the gameplay indices. The host registers each fragment under
/// `FeedbackVoice.id(voiceIndex)` and plays a sequence in order (scheduled by each clip's duration).
///
/// Note: this is the `Sound_Output_Feedback` index space (`voiceId[]` are **direct** `g_table_voices`
/// indices), distinct from `Voice_PlayAtTile`'s `g_table_voiceMapping` space used by `VoiceTable` (the
/// positional combat/effect cues + CRUMBLE/DROPEQ2P). Base-under-attack (48) is handled separately by the host.
enum FeedbackVoice {
    /// SoundID for a `g_table_voices` fragment index — a band kept above the unit-ack / announcement ids.
    static func id(_ voiceIndex: Int) -> SoundID { SoundID(2000 + voiceIndex) }

    /// The voice fragments to register: `g_table_voices` index → VOC template. `%c` = the house prefix
    /// (substituted at registration); a leading `?`/`+`/`-`/`/` load-class marker is stripped.
    static let fragments: [(voice: Int, template: String)] = [
        (29, "%cENEMY.VOC"), (30, "%cHARK.VOC"), (31, "%cATRE.VOC"), (32, "%cORDOS.VOC"),
        (33, "%cFREMEN.VOC"), (34, "%cSARD.VOC"), (35, "FILLER.VOC"), (36, "%cUNIT.VOC"), (37, "%cSTRUCT.VOC"),
        (44, "%cRADAR.VOC"), (45, "%cOFF.VOC"), (46, "%cON.VOC"), (47, "%cFRIGATE.VOC"), (48, "?%cARRIVE.VOC"),
        (49, "%cWARNING.VOC"), (50, "%cSABOT.VOC"), (51, "%cMISSILE.VOC"), (52, "%cBLOOM.VOC"),
        (53, "%cDESTROY.VOC"), (54, "%cDEPLOY.VOC"), (55, "%cAPPRCH.VOC"), (56, "%cLOCATED.VOC"),
        (57, "%cNORTH.VOC"), (58, "%cEAST.VOC"), (59, "%cSOUTH.VOC"), (60, "%cWEST.VOC"),
        (67, "%cHARVEST.VOC"), (68, "%cWORMY.VOC"),
    ]

    /// Feedback index → its fragment sequence (`g_table_voices` indices), from `g_feedback`:
    /// 1-12 = threat warnings ("warning, enemy unit approaching from the <dir>" / saboteur / sandworm-name);
    /// 13-20 = "<X> unit destroyed"; 21-24 = "<X> structure destroyed"; 28/29 = "radar on/off";
    /// 30-35 = "<house> unit deployed"; 36 = "spice bloom located"; 37 = "warning, sandworms…"; 38 = "frigate
    /// has arrived"; 39 = "warning, missile approaching"; 68-73 = "<house> harvester deployed".
    static let sequences: [UInt16: [Int]] = [
        1: [ 49, 29, 36, 55 ], 2: [ 49, 29, 36, 55, 57 ], 3: [ 49, 29, 36, 55, 58 ], 4: [ 49, 29, 36, 55, 59 ],
        5: [ 49, 29, 36, 55, 60 ],
        6: [ 49, 30, 36, 55 ], 7: [ 49, 31, 36, 55 ], 8: [ 49, 32, 36, 55 ], 9: [ 49, 33, 36, 55 ], 10: [ 49, 34, 55 ],
        11: [ 49, 35, 36, 55 ],
        12: [ 49, 50, 55 ],
        13: [ 29, 36, 53 ], 14: [ 30, 36, 53 ], 15: [ 31, 36, 53 ], 16: [ 32, 36, 53 ], 17: [ 33, 36, 53 ], 18: [ 34, 53 ],
        19: [ 35, 36, 53 ], 20: [ 50, 53 ],
        21: [ 29, 37, 53 ], 22: [ 30, 37, 53 ], 23: [ 31, 37, 53 ], 24: [ 32, 37, 53 ],
        28: [ 44, 46 ], 29: [ 44, 45 ],
        30: [ 30, 36, 54 ], 31: [ 31, 36, 54 ], 32: [ 32, 36, 54 ], 33: [ 33, 36, 54 ], 34: [ 34, 54 ], 35: [ 35, 36, 54 ],
        36: [ 52, 56 ], 37: [ 49, 68 ], 38: [ 47, 48 ], 39: [ 49, 51, 55 ],
        68: [ 30, 67, 54 ], 69: [ 31, 67, 54 ], 70: [ 32, 67, 54 ], 71: [ 33, 67, 54 ], 72: [ 34, 67, 54 ], 73: [ 35, 67, 54 ],
    ]

    /// Feedback indices that mean "a threat just appeared" — the host switches to battle music on these
    /// (`g_musicInBattle = 1`): the approaching/saboteur warnings (1-12), the sandworm warning (37), and the
    /// incoming house-missile (39).
    static let battleMusic: Set<UInt16> = [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 37, 39 ]

    /// A short on-screen banner for the feedbacks OpenDUNE pairs with a hint string (only the ones whose
    /// English text is well-known; the rest are voice-only, as the headless string table isn't loaded).
    static let notice: [UInt16: String] = [ 37: "Warning: sandworms roam the sand" ]
}
