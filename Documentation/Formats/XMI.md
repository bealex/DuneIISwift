# XMI — Miles XMIDI music

Status: Documented 2026-04-19

XMI is Miles Design's "Extended MIDI" container. Dune II ships the same score under several files per track (`DUNE0.XMI`, `DUNE0.C55`, `DUNE0.ADL`, `DUNE0.PCS`, `DUNE0.TAN`) — each is tuned for a specific synth. We only decode `.XMI` (MIDI for MT-32 / GM) because the others target Roland MT-32 / AdLib / PC-Speaker / Tandy hardware that we'd have to emulate. OPL → PCM for the `.ADL` bank is tracked as a risk in the Initial plan; if we take it on it'll land as `Formats.Adl`.

References:

- OpenDUNE `src/audio/mt32mpu.c` — the original MIDI player, including the XMI event-stream rules we mirror here.
- Miles XMIDI spec (informal; see e.g. MUNT / xmi2mid writeups).
- Our decoder: `Formats.Xmi.Song` in `Code/Core/Sources/DuneIICore/Formats/Xmi/`.

## 1. Container

XMI is an IFF `FORM`.

Two file shapes exist. Single-track files have:

```
FORM <size> XMID
    ...track chunks...
```

Multi-track files wrap multiple track forms inside an index + category:

```
FORM <size> XDIR
    INFO <size> <u16 LE numTracks>
CAT  <size> XMID
    FORM <size> XMID
        TIMB <size> ...
        EVNT <size> ...
    FORM <size> XMID
        ...
```

Dune II's shipped XMIs are single-track; the multi-track path is implemented for completeness (intro/cutscene sequencers sometimes emit multi-track files).

Track chunks:

| Tag    | Purpose                                         |
|--------|-------------------------------------------------|
| `TIMB` | MT-32 timbre list. Ignored by us; only matters if you're driving an MT-32. |
| `RBRN` | Branch table (rare in Dune II). Ignored.        |
| `EVNT` | The actual event stream — this is what we decode. |

## 2. EVNT stream

XMI differs from Standard MIDI File (SMF) in two ways.

**Delays.** Bytes strictly less than `0x80` before an event are *delay ticks* (plain integers, not VLQ). Multiple delay bytes accumulate: every byte `< 0x80` adds that many ticks to the pending delay. The next byte `≥ 0x80` is the event status.

**Note On with duration.** A `0x9n` event carries four bytes after the status: `note`, `velocity`, and a **VLQ duration** (big-endian 7-bit continuation). The note-off is implicit — the player schedules it `duration` ticks after the note-on. SMF instead requires an explicit `0x8n` event.

Other events follow normal MIDI:

| Status    | Bytes (after status)             | Notes                       |
|-----------|----------------------------------|-----------------------------|
| `0x8n`    | note, velocity                   | Note off                    |
| `0x9n`    | note, velocity, vlq_duration     | XMI-specific duration form  |
| `0xAn`    | note, pressure                   | Poly aftertouch             |
| `0xBn`    | control, value                   | Controller                  |
| `0xCn`    | program                          | Program change              |
| `0xDn`    | pressure                         | Channel aftertouch          |
| `0xEn`    | lsb, msb                         | Pitch bend                  |
| `0xFF tt` | vlq_len, data…                   | Meta event                  |

Meta event `FF 2F 00` ends the track.

## 3. SMF conversion

`Song.Track.toStandardMidiFile(ticksPerQuarter:)` converts one track to a Format-0 SMF (`MThd` + single `MTrk`). Defaults to `ticksPerQuarter = 60`. The converter:

1. Accumulates XMI delays into an absolute tick counter.
2. Emits every XMI event unchanged *except* Note On: the `0x9n` note-on drops its duration, and a synthetic `0x8n` note-off is scheduled at `currentTick + duration`.
3. Sorts all events (note-offs may land out of order among themselves and original events).
4. Emits SMF delta times (VLQ) between consecutive events.

A default tempo meta event (`FF 51 03 07 A1 20` = 500000 μs per quarter, 120 BPM) is prepended unless the source stream already carries one.

This produces a playable SMF that any GM-compatible player (`AVMIDIPlayer` included) will render. It does not reproduce every MT-32 timbre nuance — that's what the `.C55` / MT-32 bank is for, and is out of scope.

## 4. Swift API

```swift
let data = pak.body(named: "DUNE0.XMI")!
let song = try Formats.Xmi.Song.decode(data)

for track in song.tracks {
    let smf = track.toStandardMidiFile()
    // write smf to disk, feed to AVMIDIPlayer
}
```

## 5. Testing

`Core/Tests/DuneIICoreTests/XmiTests.swift`:

1. Synthetic single-event stream (note-on with duration + end-of-track) decodes to one Note On and one matching Note Off.
2. Delay accumulation: two `0x05` delay bytes before an event place the event at tick 10.
3. Meta tempo event is passed through verbatim.
4. The emitted SMF starts with `MThd … MTrk` and ends with `FF 2F 00`.
5. Real `DUNE0.XMI` in `SOUND.PAK` decodes; track count ≥ 1; the emitted SMF is non-trivial.

## 6. Related insights

- [format-xmi-delay-and-duration](../Insights/format-xmi-delay-and-duration.md) — XMI's "delay before event" and "duration after note-on" semantics, and how they map to SMF delta times + paired note-off.
