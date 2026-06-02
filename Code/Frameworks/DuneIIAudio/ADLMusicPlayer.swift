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
/// **Real-time render path.** An `AVAudioSourceNode` pulls PCM from the chip on the audio render thread,
/// ticking the driver at its 72 Hz refresh between sample boundaries (the `adlrender` host-loop, inverted into
/// a pull model). All cross-thread state lives in a `Mutex` inside a `Sendable` `RenderBox`; the render block
/// captures **only that box** (never `self`) so it stays a *nonisolated* `@Sendable` closure — AVFAudio runs
/// it on the audio IO thread, and a closure that inherited this `@MainActor` class's isolation would trap
/// there with a `_dispatch_assert_queue` / executor-isolation failure. (`Mutex`, not `nonisolated(unsafe)`,
/// per the project's concurrency rules. See insight `swift-audio-render-thread-mutex`.)
///
/// Music is host-side presentation only: it never touches the simulation, `GameState`, or sim RNG.
@MainActor
public final class ADLMusicPlayer: MusicEngine {
    /// The OPL3 chip's resampled output rate (`OPL3Chip(sampleRate:)`). 44.1 kHz stereo.
    private nonisolated static let outputRate = 44_100
    /// The Westwood ADL driver tick rate (`ADLPlayer.refreshRate`).
    private nonisolated static let refresh = 72

    private let musicDirectory: URL
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private let box = RenderBox()
    private var running = false
    /// Bumped on every (re)start/stop so a stale end-of-track callback from a track we have superseded or
    /// stopped is dropped (the render thread carries the generation it was started under).
    private var generation = 0
    private let log = Logger(subsystem: "com.lonelybytes.duneii", category: "Music")

    public var onFinished: (@MainActor () -> Void)?

    public init(musicDirectory: URL) {
        self.musicDirectory = musicDirectory
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.outputRate),
                               channels: 2, interleaved: false)!
        let node = Self.makeNode(box: box, format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        _ = engine.mainMixerNode
        // The render thread signals end-of-track through this notifier; hop back to the main actor to run the
        // policy callback. `weak self` so the node's retained box doesn't keep the player alive.
        box.notifier.withLock { notifier in
            notifier = { [weak self] gen in Task { @MainActor in self?.trackFinished(generation: gen) } }
        }
    }

    /// Build the source node in a *nonisolated* context so its render closure captures only the `Sendable`
    /// `box` and is itself nonisolated `@Sendable` — never inheriting this class's `@MainActor` isolation.
    private nonisolated static func makeNode(box: RenderBox, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            render(box: box, frameCount: frameCount, abl: audioBufferList)
        }
    }

    public func play(file: Int, song: Int, loop: Bool) {
        let url = musicDirectory.appendingPathComponent(String(format: "DUNE%d.ADL", file))
        guard let data = try? Data(contentsOf: url) else {
            log.warning("ADL music file missing: \(url.lastPathComponent, privacy: .public)")
            return
        }
        generation &+= 1
        guard install(data: data, song: song, loop: loop, generation: generation) else {
            log.error("not a valid .ADL: \(url.lastPathComponent, privacy: .public)")
            return
        }
        log.info("ADL play \(url.lastPathComponent, privacy: .public) song=\(song, privacy: .public) loop=\(loop, privacy: .public)")
        ensureRunning()
    }

    /// Build the chip + driver and hand them to the render state. `nonisolated` so the non-`Sendable` chip and
    /// player are created in a disconnected region and *sent* into the `Mutex` (rather than captured by a
    /// main-actor closure, which the compiler can't prove race-free). Returns false on a malformed `.ADL`.
    private nonisolated func install(data: Data, song: Int, loop: Bool, generation: Int) -> Bool {
        // Build the chip + driver *inside* the lock so the non-`Sendable` instances never linger as locals in
        // this region — the `Mutex`'s value stays disconnected (sendable across the audio-thread boundary).
        box.state.withLock { rs in
            let chip = OPL3Chip(sampleRate: UInt32(Self.outputRate))
            let player = ADLPlayer(chip: chip)
            guard player.load(data) else { return false }
            player.rewind(subsong: song)
            rs.start(chip: chip, player: player, loop: loop, generation: generation)
            return true
        }
    }

    public func stop() {
        generation &+= 1
        box.state.withLock { $0.silence() }
    }

    public func pause() { box.state.withLock { $0.paused = true } }
    public func resume() { box.state.withLock { $0.paused = false } }

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

    /// Main-actor end-of-track handoff from the render thread. Dropped if a newer `play`/`stop` superseded it.
    private func trackFinished(generation gen: Int) {
        guard gen == generation else { return }
        onFinished?()
    }

    // MARK: - Render thread

    /// The cross-thread state, owned by a `Sendable` reference the render closure can capture by value. The
    /// `Mutex` confines the non-`Sendable` chip/driver; the `notifier` (a `@Sendable` closure) lets the render
    /// thread hand end-of-track back to the owner without the closure ever touching `self`.
    private final class RenderBox: Sendable {
        let state = Mutex(RenderState())
        let notifier = Mutex<(@Sendable (Int) -> Void)?>(nil)

        func notify(_ generation: Int) {
            let callback = notifier.withLock { $0 }
            callback?(generation)
        }
    }

    /// Mutable playback state, owned by the `Mutex` and touched on both the main actor (swap) and the audio
    /// render thread (pull). Not `Sendable` — confinement is the lock's job.
    private final class RenderState {
        var chip: OPL3Chip?
        var player: ADLPlayer?
        var loop = false
        var paused = false
        /// `false` until the driver first reports an active channel — so a not-yet-started track isn't
        /// mistaken for a finished one on the opening ticks.
        var everAlive = false
        var finished = false
        var emitted = 0
        var ticks = 0
        var generation = 0

        func start(chip: OPL3Chip, player: ADLPlayer, loop: Bool, generation: Int) {
            self.chip = chip
            self.player = player
            self.loop = loop
            self.generation = generation
            paused = false
            everAlive = false
            finished = false
            emitted = 0
            ticks = 0
        }

        func silence() {
            chip = nil
            player = nil
            finished = true
        }
    }

    /// The `AVAudioSourceNode` render block body. Runs on the real-time audio thread; nonisolated `@Sendable`
    /// (captures only `box`). Allocation-free past the one-shot end-of-track `Task` the notifier spawns.
    private nonisolated static func render(box: RenderBox, frameCount: AVAudioFrameCount,
                                           abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
        let count = Int(frameCount)
        var finishedNow = false
        var gen = 0

        box.state.withLock { rs in
            gen = rs.generation
            guard !rs.paused, let chip = rs.chip, let player = rs.player else {
                for i in 0 ..< count { left[i] = 0; right[i] = 0 }
                return
            }
            for i in 0 ..< count {
                if !rs.finished {
                    // Fire every driver tick due by this output sample (≈ 612.5 samples/tick at 44100/72).
                    while rs.ticks * outputRate <= rs.emitted * refresh {
                        let alive = player.update()
                        rs.ticks += 1
                        if alive {
                            rs.everAlive = true
                        } else if rs.everAlive && !rs.loop {
                            rs.finished = true
                            finishedNow = true
                            break
                        }
                    }
                }
                if rs.finished {
                    left[i] = 0; right[i] = 0
                    continue
                }
                let s = chip.generateResampled()
                left[i] = Float(s.left) / 32768
                right[i] = Float(s.right) / 32768
                rs.emitted += 1
            }
        }

        if finishedNow { box.notify(gen) }
        return noErr
    }
}
