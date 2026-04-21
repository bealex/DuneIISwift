import Foundation
import DuneIICore
@preconcurrency import AVFoundation

/// VOC voice-sample playback through `AVAudioEngine` + `AVAudioPlayerNode`.
/// Dune II's `.VOC` files are 8-bit unsigned mono PCM with per-sample rates
/// in the 8-22 kHz range; we convert to 16-bit signed planar float at the
/// sample's native rate and schedule one-shot buffers on the player node.
///
/// A single `AVAudioEngine` survives for the lifetime of the app; scenes
/// share one instance via `AssetLoader` / `GameController`. Concurrent
/// `play(named:)` calls all land on the same node and queue up.
@MainActor
public final class Voice {
    public let loader: AssetLoader

    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode

    public enum VoiceError: Error, Sendable {
        case assetMissing(String)
        case bufferAllocationFailed
        case engineStartFailed(String)
    }

    public init(loader: AssetLoader) throws {
        self.loader = loader
        self.engine = AVAudioEngine()
        self.player = AVAudioPlayerNode()
        engine.attach(player)
        // Connect with a nil format — AVAudioEngine will match whatever
        // format the scheduled buffers carry. Mixer handles the
        // rate-conversion to the output.
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        do {
            try engine.start()
        } catch {
            throw VoiceError.engineStartFailed("\(error)")
        }
        player.play()
    }

    /// Loads `<name>.VOC` from the install and queues it for playback.
    /// Returns `false` when the asset doesn't exist (caller's choice to
    /// log or ignore).
    @discardableResult
    public func play(named name: String) throws -> Bool {
        guard let sound = try loader.loadVoc(named: name) else { return false }
        try schedule(sound)
        return true
    }

    /// Queues a decoded VOC. Split from `play(named:)` for testability.
    public func schedule(_ sound: Formats.Voc.Sound) throws {
        guard let buffer = Self.makeBuffer(for: sound) else {
            throw VoiceError.bufferAllocationFailed
        }
        player.scheduleBuffer(buffer, at: nil, options: [])
    }

    /// Stops any currently-playing buffer and flushes the queue.
    public func stopAll() {
        player.stop()
        player.play()
    }

    // MARK: Helpers

    /// Converts `Formats.Voc.Sound` (8-bit unsigned mono PCM) into an
    /// `AVAudioPCMBuffer` at the sample's native rate. The u8→float
    /// conversion maps `[0, 255]` → `[-1.0, +1.0]`.
    static func makeBuffer(for sound: Formats.Voc.Sound) -> AVAudioPCMBuffer? {
        guard sound.sampleRate > 0, !sound.samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(sound.sampleRate),
            channels: 1
        ) else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sound.samples.count)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(sound.samples.count)
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        for (i, byte) in sound.samples.enumerated() {
            // u8 center=128, so remap: (byte - 128) / 128.0 ∈ [-1, +1).
            channel[i] = (Float(Int(byte) - 128)) / 128.0
        }
        return buffer
    }
}
