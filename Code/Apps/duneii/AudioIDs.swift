import DuneIIContracts

extension SoundID {
    // UI feedback ids, kept above the OpenDUNE voice-id range (0…119) the sim emits so they never collide.
    static let select = SoundID(1000)        // CLICK.VOC
    static let acknowledge = SoundID(1001)   // AFFIRM.VOC
}
