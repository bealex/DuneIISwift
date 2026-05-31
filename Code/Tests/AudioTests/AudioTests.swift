import AVFoundation
import DuneIIContracts
import Testing
@testable import DuneIIAudio

/// `DuneIIAudio` — the PCM conversion + the sink contract. Actual sound output needs a real audio device
/// (the sink degrades to silent without one), so the tests cover the testable parts: the 8-bit→float
/// conversion, buffer building, `NullAudio`, and that the engine sink never crashes when there's no device.
@Suite("Audio")
@MainActor
struct AudioTests {
    @Test("unsigned-8-bit PCM maps to centred float (-1…~1, 128 → 0)")
    func pcm8ToFloat() {
        #expect(Pcm8.toFloat(128) == 0)
        #expect(Pcm8.toFloat(0) == -1)
        #expect(abs(Pcm8.toFloat(255) - (127.0 / 128.0)) < 1e-6)
        #expect(Pcm8.toFloat(192) == 0.5)
    }

    @Test("makeBuffer builds a float32 mono buffer; same rate keeps the frame count, a different rate resamples")
    func makeBuffer() throws {
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 1, interleaved: false)!
        let pcm: [UInt8] = [128, 0, 255, 64, 192, 128]

        // Same rate → no resample: frame count + values preserved.
        let same = try #require(EngineAudioSink.makeBuffer(pcm8: pcm, sampleRate: 22_050, target: target))
        #expect(same.frameLength == AVAudioFrameCount(pcm.count))
        #expect(same.format.sampleRate == 22_050 && same.format.channelCount == 1)
        #expect(same.floatChannelData![0][0] == 0)        // 128 → 0
        #expect(same.floatChannelData![0][1] == -1)       // 0 → -1

        // Half the rate → upsampled ≈ 2× the frames, in the target format.
        let resampled = try #require(EngineAudioSink.makeBuffer(pcm8: pcm, sampleRate: 11_025, target: target))
        #expect(resampled.format.sampleRate == 22_050)
        #expect(resampled.frameLength > AVAudioFrameCount(pcm.count))

        // Empty / invalid input → nil.
        #expect(EngineAudioSink.makeBuffer(pcm8: [], sampleRate: 22_050, target: target) == nil)
        #expect(EngineAudioSink.makeBuffer(pcm8: pcm, sampleRate: 0, target: target) == nil)
    }

    @Test("NullAudio is a safe no-op")
    func nullAudio() {
        let sink: AudioSink = NullAudio()
        sink.register(SoundID(1), sampleRate: 22_050, pcm8: [1, 2, 3])
        sink.play(SoundEvent(sound: SoundID(1)))
        sink.play(SoundID(2))
        sink.stopAll()   // no crash, no output
    }

    @Test("EngineAudioSink registers + plays without crashing, even with no audio device")
    func engineGraceful() {
        let sink = EngineAudioSink(voices: 4)
        sink.register(SoundID(7), sampleRate: 22_050, pcm8: [UInt8](repeating: 128, count: 100))
        // start() may fail (no output device on a CI box); either way play must be safe.
        _ = sink.start()
        sink.play(SoundEvent(sound: SoundID(7)))            // registered
        sink.play(SoundEvent(sound: SoundID(999)))          // unregistered → ignored
        sink.stopAll()
    }
}
