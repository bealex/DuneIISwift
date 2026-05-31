import AVFoundation
import DuneIIContracts

/// Low-latency, polyphonic `AudioSink` built on `AVAudioEngine`. Sounds are **pre-decoded** into
/// `AVAudioPCMBuffer`s at register time (no decode/IO on the play path) and a **pool of player nodes** is
/// kept running, so `play` is a single `scheduleBuffer(at: nil, options: .interrupts)` — it starts at the
/// next render quantum (no perceptible delay) and **mixes** with other voices. Voices are handed out
/// round-robin across the pool; only when more than `voices` sounds overlap does a new one cut the oldest.
///
/// All sounds are converted to one canonical format (float32 mono @ `sampleRate`) so every node↔mixer
/// connection shares a format and any buffer can play on any node. If the host has no audio output device
/// (`start()` throws — e.g. a CI box), it degrades to silent: `play` simply no-ops.
@MainActor
public final class EngineAudioSink: AudioSink {
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var nodes: [AVAudioPlayerNode] = []
    private var buffers: [SoundID: AVAudioPCMBuffer] = [:]
    private var next = 0
    private(set) var running = false

    /// - Parameters:
    ///   - voices: simultaneous voices (player nodes) before a new sound steals the oldest. 24 ≫ Dune II's
    ///     real concurrency.
    ///   - sampleRate: the canonical mixing rate every sound is resampled to.
    public init(voices: Int = 24, sampleRate: Double = 22_050) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 1, interleaved: false)!
        for _ in 0 ..< max(1, voices) {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes.append(node)
        }
        _ = engine.mainMixerNode   // realise the mixer before start
    }

    /// Start the audio engine and the player-node pool. Idempotent; on a box with no output device it
    /// fails quietly (the sink stays silent) rather than throwing into the host.
    @discardableResult
    public func start() -> Bool {
        guard !running else { return true }
        engine.prepare()
        do {
            try engine.start()
            for node in nodes { node.play() }   // keep the pool running, so scheduleBuffer plays at once
            running = true
        } catch {
            running = false
        }
        return running
    }

    public func register(_ id: SoundID, sampleRate: Int, pcm8: [UInt8]) {
        if let buffer = Self.makeBuffer(pcm8: pcm8, sampleRate: sampleRate, target: format) {
            buffers[id] = buffer
        }
    }

    public func play(_ event: SoundEvent) {
        guard running, let buffer = buffers[event.sound] else { return }
        let node = nodes[next]
        next = (next + 1) % nodes.count
        // `.interrupts` replaces whatever is on this node, so the new sound starts immediately even on a
        // busy voice (round-robin makes that the rare, oldest one).
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    public func stopAll() {
        for node in nodes { node.stop() }
        if running { for node in nodes { node.play() } }   // keep them running for the next play
    }

    /// Convert unsigned 8-bit mono PCM @ `sampleRate` into a float32 mono buffer in the `target` format,
    /// linear-resampling when the rates differ (adequate for these low-fi VOC samples). `nil` on empty input.
    static func makeBuffer(pcm8: [UInt8], sampleRate: Int, target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !pcm8.isEmpty, sampleRate > 0 else { return nil }
        let source = pcm8.map(Pcm8.toFloat)
        let n = source.count

        // Output frame count at the target rate (1:1 when the rates match).
        let outCount = Int(target.sampleRate) == sampleRate
            ? n
            : max(1, Int((Double(n) * target.sampleRate / Double(sampleRate)).rounded()))
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(outCount)) else { return nil }
        output.frameLength = AVAudioFrameCount(outCount)
        let out = output.floatChannelData![0]

        if outCount == n {
            for i in 0 ..< n { out[i] = source[i] }
        } else {
            let step = Double(n - 1) / Double(max(1, outCount - 1))   // source samples per output sample
            for i in 0 ..< outCount {
                let pos = Double(i) * step
                let i0 = min(Int(pos), n - 1), i1 = min(i0 + 1, n - 1)
                let frac = Float(pos - Double(i0))
                out[i] = source[i0] + (source[i1] - source[i0]) * frac   // linear interpolation
            }
        }
        return output
    }
}

/// Unsigned-8-bit-PCM → float conversion (centre 128 → 0), shared + pure so it can be tested without audio.
public enum Pcm8 {
    /// One sample: `0…255` (centre 128) → `-1…~1`.
    public static func toFloat(_ sample: UInt8) -> Float { (Float(sample) - 128) / 128 }
}
