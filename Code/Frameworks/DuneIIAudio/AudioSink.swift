import DuneIIContracts

/// Audio — the `sim → audio` driver. The host registers each sound's PCM under a `SoundID` once, then plays
/// `SoundEvent`s. Implementations: `NullAudio` (no-op, headless/tests) and `EngineAudioSink` (AVAudioEngine,
/// low-latency + polyphonic). Depends only on `DuneIIContracts` (the `SoundEvent` vocabulary).
///
/// `@MainActor`: audio is a UI-side presentation leaf driven from the host's main thread, where "play now"
/// is called (from input handlers / the render loop) with no actor hop.
@MainActor
public protocol AudioSink: AnyObject {
    /// Register (pre-decode) a sound so a later `play` has **no load latency**. `pcm8` is unsigned 8-bit
    /// mono PCM (the VOC sample format) at `sampleRate` Hz. Re-registering an id replaces it.
    func register(_ id: SoundID, sampleRate: Int, pcm8: [UInt8])

    /// Play a registered sound **immediately**, mixing with anything already playing. An unregistered or
    /// not-yet-started sink ignores it. A `SoundEvent` carrying a world position is attenuated by its
    /// distance from the listener (`setListener`); a position-less event plays at full volume.
    func play(_ event: SoundEvent)

    /// Silence every currently-playing voice.
    func stopAll()

    /// Set the listener (camera centre) in **sub-tile** world units (256/tile), for distance attenuation.
    func setListener(x: Int, y: Int)
}

public extension AudioSink {
    func setListener(x: Int, y: Int) {}  // default: no attenuation (NullAudio / sinks that don't care)
}

public extension AudioSink {
    /// Convenience: play a global (UI) sound by id.
    func play(_ id: SoundID) { play(SoundEvent(sound: id)) }
}

/// The no-op sink: headless runs, tests, and any host with audio disabled. Registers/plays nothing.
@MainActor
public final class NullAudio: AudioSink {
    public init() {}

    public func register(_ id: SoundID, sampleRate: Int, pcm8: [UInt8]) {}

    public func play(_ event: SoundEvent) {}

    public func stopAll() {}
}
