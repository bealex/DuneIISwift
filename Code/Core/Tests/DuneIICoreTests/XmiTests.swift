import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Xmi")
struct XmiTests {
    // MARK: Event stream parsing

    @Test("note-on with duration emits a paired note-off")
    func noteOnWithDuration() throws {
        // EVNT:
        //   90 3C 7F 10   - note on ch 0, note 60, vel 127, duration 0x10 (VLQ single byte)
        //   FF 2F 00      - end of track
        let evnt = Data([0x90, 0x3C, 0x7F, 0x10, 0xFF, 0x2F, 0x00])
        let events = try Formats.Xmi.parseEvents(evnt)
        // Expect 2 events: the note-on and the scheduled note-off, plus the meta.
        // Tick 0:  note on
        // Tick 16: note off
        // Tick 0:  meta end-of-track (fires before duration expires, but
        //          conversion should still emit it)
        let notes = events.filter { ($0.bytes[0] & 0xF0) == 0x90 || ($0.bytes[0] & 0xF0) == 0x80 }
        #expect(notes.count == 2)
        #expect(notes[0].tick == 0)
        #expect(notes[0].bytes[0] & 0xF0 == 0x90)
        #expect(notes[1].tick == 16)
        #expect(notes[1].bytes[0] & 0xF0 == 0x80)
    }

    @Test("delay bytes before an event accumulate into the event's tick")
    func delayAccumulation() throws {
        // Two delay bytes: 0x05 0x05 → tick 10.
        // Then a program change (0xC0 program=5), then end-of-track.
        let evnt = Data([0x05, 0x05, 0xC0, 0x05, 0xFF, 0x2F, 0x00])
        let events = try Formats.Xmi.parseEvents(evnt)
        let progChange = events.first(where: { $0.bytes[0] == 0xC0 })!
        #expect(progChange.tick == 10)
    }

    @Test("meta tempo event is passed through untouched")
    func metaTempo() throws {
        // FF 51 03 07 A1 20  — 500000 μs per quarter
        let evnt = Data([0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, 0xFF, 0x2F, 0x00])
        let events = try Formats.Xmi.parseEvents(evnt)
        let tempo = events.first(where: { $0.bytes[0] == 0xFF && $0.bytes[1] == 0x51 })
        #expect(tempo != nil)
        #expect(Array(tempo!.bytes.suffix(3)) == [0x07, 0xA1, 0x20])
    }

    // MARK: SMF emission

    @Test("emitted SMF has MThd/MTrk framing and ends with FF 2F 00")
    func smfFraming() throws {
        let evnt = Data([0x90, 0x3C, 0x7F, 0x10, 0xFF, 0x2F, 0x00])
        let track = Formats.Xmi.Song.Track(events: try Formats.Xmi.parseEvents(evnt))
        let smf = track.toStandardMidiFile(ticksPerQuarter: 60)

        #expect(String(bytes: smf[0..<4], encoding: .ascii) == "MThd")
        // Header length should be 6.
        let hdrLen = (UInt32(smf[4]) << 24) | (UInt32(smf[5]) << 16) | (UInt32(smf[6]) << 8) | UInt32(smf[7])
        #expect(hdrLen == 6)
        #expect(String(bytes: smf[14..<18], encoding: .ascii) == "MTrk")

        // Last three bytes are the end-of-track meta.
        let tail = Array(smf.suffix(3))
        #expect(tail == [0xFF, 0x2F, 0x00])
    }

    @Test("VLQ delta times are emitted correctly")
    func smfDeltaEncoding() throws {
        // Single event at tick 127 -> delta 127 (single byte 0x7F).
        // Single event at tick 128 -> delta 128 (two bytes 0x81 0x00 per SMF VLQ).
        let eventsAt127: [Formats.Xmi.Event] = [
            Formats.Xmi.Event(tick: 127, bytes: [0xFF, 0x2F, 0x00])
        ]
        let smfA = Formats.Xmi.Song.Track(events: eventsAt127).toStandardMidiFile(ticksPerQuarter: 60)
        // Hunt for the track body start: MTrk length header at offset 14..17, track bytes start at 22.
        // Remove any injected default tempo event if present.
        #expect(smfA.contains(0x7F))

        let eventsAt128: [Formats.Xmi.Event] = [
            Formats.Xmi.Event(tick: 128, bytes: [0xFF, 0x2F, 0x00])
        ]
        let smfB = Formats.Xmi.Song.Track(events: eventsAt128).toStandardMidiFile(ticksPerQuarter: 60)
        // 128 as VLQ = 0x81 0x00.
        #expect(containsSubsequence(smfB, [0x81, 0x00]))
    }

    // MARK: Container (synthetic single-track FORM XMID)

    @Test("single-track FORM XMID decodes to one track")
    func singleTrackForm() throws {
        let evnt: [UInt8] = [0x90, 0x3C, 0x7F, 0x08, 0xFF, 0x2F, 0x00]
        let form = buildSingleTrackXmi(evnt: Data(evnt))
        let song = try Formats.Xmi.Song.decode(form)
        #expect(song.tracks.count == 1)
        #expect(song.tracks[0].events.contains(where: { $0.bytes[0] & 0xF0 == 0x90 }))
    }

    // MARK: Real-world smoke test

    @Test("real DUNE0.XMI decodes and produces SMF")
    func realXmi() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("SOUND.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let body = archive.body(named: "DUNE0.XMI") else { return }
        let song = try Formats.Xmi.Song.decode(body)
        #expect(song.tracks.count >= 1)
        let smf = song.tracks[0].toStandardMidiFile()
        #expect(smf.count > 30)
        #expect(Array(smf.suffix(3)) == [0xFF, 0x2F, 0x00])
    }
}

// MARK: - Helpers

private func containsSubsequence(_ haystack: Data, _ needle: [UInt8]) -> Bool {
    guard needle.count <= haystack.count else { return false }
    for i in 0...(haystack.count - needle.count) {
        if Array(haystack[i..<(i + needle.count)]) == needle { return true }
    }
    return false
}

private func buildSingleTrackXmi(evnt: Data) -> Data {
    // Inner FORM XMID containing just an EVNT chunk (pad length to even).
    var inner = Data()
    inner.append(contentsOf: Array("XMID".utf8))
    inner.append(contentsOf: Array("EVNT".utf8))
    inner.append(uint32BE: UInt32(evnt.count))
    inner.append(evnt)
    if evnt.count % 2 != 0 { inner.append(0) }

    var form = Data("FORM".utf8)
    form.append(uint32BE: UInt32(inner.count))
    form.append(inner)
    return form
}

private extension Data {
    mutating func append(uint32BE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
