# XMI puts delays *before* events and note-off *inside* note-on

- **Discovered**: 2026-04-19 · `Code/Core/Sources/DuneIICore/Formats/Xmi/XmiSong.swift`
- **Category**: format
- **Applies to**: `Formats.Xmi.Song`, the SMF converter, the future `AVMIDIPlayer` driver.

## The fact

XMI's event stream deviates from Standard MIDI in two ways.

1. **Delay bytes before events.** Any byte with value `< 0x80` that precedes an event is a plain integer tick count. Multiple delay bytes accumulate additively (`total = sum of bytes`) — not VLQ-style shifted concatenation. The first byte `>= 0x80` is the status byte of the next event. SMF, by contrast, uses a VLQ delta time before *every* event.

2. **Note-off as part of note-on.** A `0x9n` event carries four bytes: note, velocity, **VLQ duration**. The player schedules the note-off internally; there is no explicit `0x8n` in the stream. SMF requires the explicit note-off.

## Why it matters

If you treat XMI delay bytes as VLQ, multi-byte delays parse as
absurdly large tick counts (2 × 0x05 parses as `(5 << 7) | 5 = 645`,
not `10`). If you treat the 4th byte of a note-on as the start of the next event, you read a random byte as a status.

For SMF conversion: you must hold note-on events alongside a "schedule" of pending note-offs; emit them at the right absolute tick; and be mindful that the original XMI EOT often fires *before* a scheduled note-off. We strip the source EOT and let the SMF writer emit a fresh one at the true end — otherwise the SMF has a non-EOT event after its EOT, which most players reject.

## Where it lives in our code

- `Formats.Xmi.parseEvents` — the delay/duration loop and EOT strip.
- `SmfWriter.write` — appends a fresh EOT, injects a default tempo.
- `Tests/DuneIICoreTests/XmiTests.swift::noteOnWithDuration` and `::delayAccumulation` pin down both mechanics.

## Where it lives in the reference

OpenDUNE `src/audio/mt32mpu.c::MPU_Interrupt`:

```c
status = data->sound[0];
if (status < 0x80) {
    data->sound++;
    data->delay = status;  /* plain integer, not VLQ */
    break;
}
```

`MPU_NoteOn` reads `chan, note, velocity` and then a **VLQ duration** (`while (data->sound[len++] & 0x80)`), scheduling the paired note-off in `data->noteOnDuration[]`.
