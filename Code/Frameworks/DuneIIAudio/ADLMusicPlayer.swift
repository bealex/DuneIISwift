import AVFoundation
import Foundation
import os
import Synchronization
import SwiftOPL3
import WestwoodADL

/// Plays Dune II's music through the **authentic DOS AdLib FM path**: the Westwood `.ADL` files synthesised on
/// an emulated **OPL3 (YMF262)** chip — `WestwoodADL.ADLPlayer` driving a `SwiftOPL3.OPL3Chip`, exactly as the
/// DOS AdLib hardware did. This is the `.adlib` `MusicBackend`; `MusicPlayer` is the `.midi` one. The same
/// OpenDUNE `(file, song)` selection index resolves here to `DUNE<file>.ADL`, subsong `song` (the ADL track
/// index matches the XMIDI sequence index 1:1 — see `Documentation/Architecture/Music.OPL2.md` §7).
///
/// **Producer / consumer, off the audio thread.** OPL3 emulation is heavy DSP — far too heavy to run inside
/// the real-time `AVAudioSourceNode` render callback (doing so misses the render deadline and the music
/// glitches/drops out). So a dedicated **background producer thread** runs the chip + driver and fills a PCM
/// **ring buffer** ahead of playback; the audio callback merely copies frames out of the ring (cheap,
/// real-time-safe) or emits silence on underrun. All cross-thread state lives in `Mutex`es inside a `Sendable`
/// box, the chip/driver are confined to the producer thread, and the render closure captures only the box (no
/// `self`) so it stays a nonisolated `@Sendable` closure — see insight `swift-audio-render-thread-mutex`.
///
/// Music is host-side presentation only: it never touches the simulation, `GameState`, or sim RNG.
@MainActor
public final class ADLMusicPlayer: MusicEngine {
    /// The OPL3 chip's resampled output rate (`OPL3Chip(sampleRate:)`). 44.1 kHz stereo.
    private nonisolated static let outputRate = 44_100
    /// The Westwood ADL driver tick rate (`ADLPlayer.refreshRate`).
    private nonisolated static let refresh = 72
    private nonisolated static let channels = 2

    private let musicDirectory: URL
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private let shared = Shared()
    private var running = false
    private var producerStarted = false
    /// Bumped on every (re)start/stop so a stale end-of-track callback from a track we have superseded or
    /// stopped is dropped (the producer carries the generation it was started under).
    private var generation = 0
    private let log = Logger(subsystem: "com.lonelybytes.duneii", category: "Music")

    public var onFinished: (@MainActor () -> Void)?

    public init(musicDirectory: URL) {
        self.musicDirectory = musicDirectory
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.outputRate),
                               channels: 2, interleaved: false)!
        let node = Self.makeNode(shared: shared, format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        _ = engine.mainMixerNode
        // The producer signals end-of-track through this notifier; hop back to the main actor to run the
        // policy callback. `weak self` so neither the node-retained box nor the producer keeps the player alive.
        shared.notifier.withLock { notifier in
            notifier = { [weak self] gen in Task { @MainActor in self?.trackFinished(generation: gen) } }
        }
    }

    deinit {
        // Stop the producer thread; the engine + node tear down with the class (their closures hold only the
        // `Sendable` box, never `self`, so the player can deallocate).
        shared.cancelled.withLock { $0 = true }
    }

    /// Build the source node in a *nonisolated* context so its render closure captures only the `Sendable`
    /// `shared` box and is itself nonisolated `@Sendable` — never inheriting this class's `@MainActor`
    /// isolation (which would trap on the audio IO thread).
    private nonisolated static func makeNode(shared: Shared, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            consume(shared: shared, frameCount: frameCount, abl: audioBufferList)
        }
    }

    public func play(file: Int, song: Int, loop: Bool) {
        let url = musicDirectory.appendingPathComponent(String(format: "DUNE%d.ADL", file))
        guard let data = try? Data(contentsOf: url) else {
            log.warning("ADL music file missing: \(url.lastPathComponent, privacy: .public)")
            return
        }
        generation &+= 1
        let gen = generation
        shared.command.withLock { $0 = Command(data: data, song: song, loop: loop, generation: gen,
                                               paused: false, stopped: false) }
        log.info("ADL play \(url.lastPathComponent, privacy: .public) song=\(song, privacy: .public) loop=\(loop, privacy: .public)")
        ensureRunning()
        ensureProducer()
    }

    public func stop() {
        generation &+= 1
        let gen = generation
        shared.command.withLock { $0 = Command(data: nil, song: 0, loop: false, generation: gen,
                                               paused: false, stopped: true) }
    }

    public func pause() { shared.command.withLock { $0.paused = true } }
    public func resume() { shared.command.withLock { $0.paused = false } }

    /// Start the audio engine on first use; degrade to silent on a box with no output device (like
    /// `EngineAudioSink`) rather than throwing into the host.
    private func ensureRunning() {
        guard !running else { return }
        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            running = false
            log.error("music engine start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Start the background synthesis thread once. It runs until the player deallocates (`deinit` sets
    /// `cancelled`).
    private func ensureProducer() {
        guard !producerStarted else { return }
        producerStarted = true
        Self.makeProducerThread(shared: shared).start()
    }

    private nonisolated static func makeProducerThread(shared: Shared) -> Thread {
        let thread = Thread { produce(shared: shared) }
        thread.name = "duneii.adl.producer"
        thread.qualityOfService = .userInitiated
        return thread
    }

    /// Main-actor end-of-track handoff from the producer. Dropped if a newer `play`/`stop` superseded it.
    private func trackFinished(generation gen: Int) {
        guard gen == generation else { return }
        onFinished?()
    }

    // MARK: - Shared state (Sendable; the producer thread and the audio thread meet here)

    /// Cross-thread state, captured by value (it's a `Sendable` reference) by the render closure and the
    /// producer thread. The `Mutex`es confine the non-`Sendable` work and the volatile flags.
    private final class Shared: Sendable {
        /// PCM the producer has rendered ahead, drained by the audio callback.
        let ring = Mutex(Ring())
        /// The desired playback state (set by the main actor, read by both threads). `Data` is COW, so copying
        /// the struct out under the lock is cheap.
        let command = Mutex(Command())
        /// End-of-track hand-back to the owner — never captures `self` directly.
        let notifier = Mutex<(@Sendable (Int) -> Void)?>(nil)
        /// Set by `deinit` to terminate the producer thread.
        let cancelled = Mutex(false)

        func notify(_ generation: Int) {
            let callback = notifier.withLock { $0 }
            callback?(generation)
        }
    }

    /// What to play. A value type so the main actor swaps it atomically under the lock.
    private struct Command: Sendable {
        var data: Data?
        var song = 0
        var loop = false
        var generation = 0
        var paused = false
        var stopped = false
    }

    /// A fixed-capacity stereo (interleaved L/R) float ring buffer — ~1 s of lookahead. Single producer
    /// (synthesis thread) / single consumer (audio thread), each holding the `Mutex` only for the brief copy.
    private struct Ring {
        static let capacityFrames = ADLMusicPlayer.outputRate    // 1 second
        private var buffer = [Float](repeating: 0, count: capacityFrames * ADLMusicPlayer.channels)
        private var head = 0        // read cursor (in floats; always even)
        private var tail = 0        // write cursor (in floats; always even)
        private var available = 0   // floats ready to read

        var freeFrames: Int { (buffer.count - available) / ADLMusicPlayer.channels }

        mutating func clear() { head = 0; tail = 0; available = 0 }

        /// Append `frames` stereo frames from `src` (interleaved), dropping any that don't fit.
        mutating func write(_ src: [Float], frames: Int) {
            let n = min(frames * ADLMusicPlayer.channels, buffer.count - available)
            for i in 0 ..< n {
                buffer[tail] = src[i]
                tail = (tail + 1) % buffer.count
            }
            available += n
        }

        /// Pop up to `frames` stereo frames into the two (non-interleaved) channel pointers. Returns the count
        /// actually produced (fewer than `frames` on underrun).
        mutating func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
            let n = min(frames, available / ADLMusicPlayer.channels)
            for f in 0 ..< n {
                left[f] = buffer[head]
                right[f] = buffer[head + 1]
                head = (head + 2) % buffer.count
                available -= 2
            }
            return n
        }
    }

    // MARK: - Audio thread (consumer)

    /// The `AVAudioSourceNode` render block body. Real-time-safe: copies already-rendered frames out of the
    /// ring (or silence when paused/stopped/underrunning). Nonisolated `@Sendable` (captures only `shared`).
    private nonisolated static func consume(shared: Shared, frameCount: AVAudioFrameCount,
                                            abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
        let count = Int(frameCount)

        let silent = shared.command.withLock { $0.paused || $0.stopped }
        let produced = silent ? 0 : shared.ring.withLock { $0.read(left: left, right: right, frames: count) }
        if produced < count {
            for i in produced ..< count { left[i] = 0; right[i] = 0 }
        }
        return noErr
    }

    // MARK: - Producer thread (synthesis)

    /// The background synthesis loop: owns the chip + driver (confined to this thread), renders PCM ahead into
    /// the ring whenever there's room, and reloads when the command's generation changes.
    private nonisolated static func produce(shared: Shared) {
        var chip: OPL3Chip?
        var player: ADLPlayer?
        var loadedGeneration = Int.min
        var everAlive = false       // armed once the driver reports an active channel (ignore opening ticks)
        var finished = false
        var ticks = 0
        var emitted = 0
        let chunkFrames = 1024
        var scratch = [Float](repeating: 0, count: chunkFrames * channels)

        while true {
            if shared.cancelled.withLock({ $0 }) { return }
            let command = shared.command.withLock { $0 }

            if command.generation != loadedGeneration {
                loadedGeneration = command.generation
                everAlive = false; finished = false; ticks = 0; emitted = 0
                shared.ring.withLock { $0.clear() }
                if let data = command.data, !command.stopped {
                    let newChip = OPL3Chip(sampleRate: UInt32(outputRate))
                    let newPlayer = ADLPlayer(chip: newChip)
                    if newPlayer.load(data) {
                        newPlayer.rewind(subsong: command.song)
                        chip = newChip; player = newPlayer
                    } else {
                        chip = nil; player = nil
                    }
                } else {
                    chip = nil; player = nil
                }
            }

            guard let chip, let player, !command.stopped else {
                Thread.sleep(forTimeInterval: 0.02); continue
            }
            if command.paused || finished {
                Thread.sleep(forTimeInterval: 0.01); continue
            }
            if shared.ring.withLock({ $0.freeFrames }) < chunkFrames {
                Thread.sleep(forTimeInterval: 0.005); continue   // ring full — let the consumer drain
            }

            var produced = 0
            var hitEnd = false
            for f in 0 ..< chunkFrames {
                // Fire every driver tick due by this output sample (≈ 612.5 samples/tick at 44100/72).
                while ticks * outputRate <= emitted * refresh {
                    let alive = player.update()
                    ticks += 1
                    if alive {
                        everAlive = true
                    } else if everAlive && !command.loop {
                        finished = true; hitEnd = true; break
                    }
                }
                if finished { break }
                let s = chip.generateResampled()
                scratch[f * 2] = Float(s.left) / 32768
                scratch[f * 2 + 1] = Float(s.right) / 32768
                emitted += 1
                produced += 1
            }

            if produced > 0 { shared.ring.withLock { $0.write(scratch, frames: produced) } }
            if hitEnd { shared.notify(loadedGeneration) }
        }
    }
}
