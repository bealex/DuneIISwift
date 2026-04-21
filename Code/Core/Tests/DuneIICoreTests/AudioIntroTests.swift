import Foundation
import Testing
@testable import DuneIICore
@testable import DuneIIRendering

@Suite("Audio + Intro — Jukebox / Voice / WSA loader")
struct AudioIntroTests {

    @Test("AssetLoader.loadWsa decodes INTRO.WSA to a non-empty frame set")
    @MainActor
    func loadIntroWsa() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        guard install.body(of: "INTRO.WSA") != nil else { return }
        let wsa = try assets.loadWsa(named: "INTRO.WSA")
        #expect(wsa.frames.count > 0)
        #expect(wsa.width == 320)
        #expect(wsa.height == 200)
        // Every frame is a usable CGImage of that size.
        for img in wsa.frames.prefix(3) {
            #expect(img.width == 320)
            #expect(img.height == 200)
        }
    }

    @Test("AssetLoader.loadXmiAsSMF converts the first track of DUNE0.XMI")
    @MainActor
    func loadXmiAsSMF() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        guard install.body(of: "DUNE0.XMI") != nil else { return }
        let smf = try assets.loadXmiAsSMF(named: "DUNE0.XMI")
        #expect(smf != nil)
        // Standard MIDI files start with the "MThd" chunk tag.
        let header = smf!.prefix(4)
        #expect(header == Data([0x4D, 0x54, 0x68, 0x64]))
    }

    @Test("AssetLoader.loadVoc decodes a voice sample into PCM")
    @MainActor
    func loadVoc() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        // Pick any .VOC from the install.
        let names = install.assetNames(startingWith: "").filter { $0.hasSuffix(".VOC") }
        guard let name = names.first else { return }
        let sound = try assets.loadVoc(named: name)
        #expect(sound != nil)
        if let s = sound {
            #expect(s.sampleRate > 0)
            #expect(!s.samples.isEmpty)
        }
    }

    @Test("Jukebox plays a real XMI track without throwing")
    @MainActor
    func jukeboxPlay() throws {
        guard let root = TestInstall.locate() else { return }
        let install = try Installation(rootDirectory: root)
        let assets = try AssetLoader(installation: install)
        guard install.body(of: "DUNE0.XMI") != nil else { return }
        let jukebox = Jukebox(loader: assets)
        let started = try jukebox.play(named: "DUNE0.XMI")
        #expect(started)
        jukebox.stop()
        #expect(jukebox.isPlaying == false)
    }

    @Test("Voice builds an AVAudioPCMBuffer from a decoded VOC")
    @MainActor
    func voiceBufferShape() {
        // Synthetic test — no install needed. 8 kHz, 1000 samples.
        let sound = Formats.Voc.Sound(
            sampleRate: 8000,
            samples: (0..<1000).map { UInt8(truncatingIfNeeded: $0) }
        )
        let buffer = Voice.makeBuffer(for: sound)
        #expect(buffer != nil)
        if let b = buffer {
            #expect(b.format.sampleRate == 8000)
            #expect(b.frameLength == 1000)
            // First sample is 0 → (0 - 128) / 128.0 = -1.0.
            let ch = b.floatChannelData![0]
            #expect(ch[0] == -1.0)
            // Sample 128 should map to exactly 0.0.
            #expect(ch[128] == 0.0)
        }
    }

    @Test("Voice.makeBuffer rejects zero-rate or empty-sample input")
    @MainActor
    func voiceBufferGuards() {
        let empty = Formats.Voc.Sound(sampleRate: 8000, samples: [])
        #expect(Voice.makeBuffer(for: empty) == nil)
        let zeroRate = Formats.Voc.Sound(sampleRate: 0, samples: [0, 1, 2])
        #expect(Voice.makeBuffer(for: zeroRate) == nil)
    }
}
