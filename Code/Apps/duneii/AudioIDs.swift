import DuneIIContracts

extension SoundID {
    // UI feedback ids, kept above the OpenDUNE voice-id range (0…119) the sim emits so they never collide.
    static let select = SoundID(1000)        // CLICK.VOC
    static let acknowledge = SoundID(1001)   // AFFIRM.VOC (voice 17)
    // The unit "speaks" voices (`g_table_voices` 17–22, language-prefix `%c`=Z for English). Played on
    // select (REPORT1/2) + on order (the action's voice / a random REPORT3/AFFIRM) — see `playSelectVoice`
    // / `playOrderVoice`, faithful to `unit.c:1730` + `viewport.c:182`.
    static let report1 = SoundID(1002)       // REPORT1.VOC — select (foot unit)
    static let report2 = SoundID(1003)       // REPORT2.VOC — select (vehicle)
    static let report3 = SoundID(1004)       // REPORT3.VOC — harvest order / random vehicle ack
    static let moveOut = SoundID(1005)       // MOVEOUT.VOC — move order
    static let overOut = SoundID(1006)       // OVEROUT.VOC — attack/retreat order
}
