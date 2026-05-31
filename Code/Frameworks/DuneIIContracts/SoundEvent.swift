/// A sound the simulation (or the host UI) wants played — the `sim → audio` half of the Contracts seam
/// (`FrameInfo` is sim→render, `Command` is input→sim). Presentation-free: it names a sound by an opaque
/// `SoundID` and carries an optional world position (for distance attenuation), so neither the sim nor the
/// audio layer needs the other's types. The host registers PCM under each `SoundID` and plays events on an
/// `AudioSink` (`DuneIIAudio`).
public struct SoundEvent: Sendable, Equatable, Codable {
    /// Which sound to play (the key the host registered the PCM under).
    public var sound: SoundID
    /// The sound's world position in sub-tile units (256/tile), for attenuation; `nil` = a UI/global sound.
    public var positionX: Int?
    public var positionY: Int?

    public init(sound: SoundID, positionX: Int? = nil, positionY: Int? = nil) {
        self.sound = sound
        self.positionX = positionX
        self.positionY = positionY
    }
}

/// An opaque, extensible sound identifier (a stable integer key). The sim/host define named constants in
/// extensions (`static let cantBuild = SoundID(12)`), the audio layer maps it to a loaded PCM buffer.
public struct SoundID: Hashable, Sendable, RawRepresentable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}
