import Foundation

extension Formats {
    /// Miles XMIDI container. See `Documentation/Formats/XMI.md` for the
    /// full layout and the SMF conversion semantics.
    public enum Xmi {
        /// A single resolved event in a track. `tick` is absolute (from the
        /// start of the track); `bytes` is the MIDI-wire representation of
        /// the event **without** any XMI-specific extras (note-on duration
        /// has been stripped and a scheduled note-off appears as its own
        /// event at `tick + duration`).
        public struct Event: Sendable, Equatable {
            public var tick: UInt32
            public var bytes: [UInt8]

            public init(tick: UInt32, bytes: [UInt8]) {
                self.tick = tick
                self.bytes = bytes
            }
        }

        public enum DecodeError: Error, Equatable, Sendable {
            case notIff
            case missingChunk(String)
            case truncated
            case unexpectedStatus(UInt8, at: Int)
        }

        public struct Song: Sendable {
            public let tracks: [Track]

            public struct Track: Sendable {
                public let events: [Event]

                public init(events: [Event]) {
                    self.events = events
                }

                /// Emits a Format-0 Standard MIDI File (MThd + one MTrk).
                public func toStandardMidiFile(ticksPerQuarter: UInt16 = 60) -> Data {
                    return SmfWriter.write(events: events, ticksPerQuarter: ticksPerQuarter)
                }
            }

            public static func decode(_ data: Data) throws -> Song {
                guard data.count >= 12 else { throw DecodeError.notIff }
                let base = data.startIndex
                guard readFourCC(data, at: base) == "FORM" else { throw DecodeError.notIff }
                let outerSize = Int(readU32BE(data, at: base + 4))
                let outerTag = readFourCC(data, at: base + 8)
                let outerBody = base + 12

                switch outerTag {
                case "XDIR":
                    // Multi-track: XDIR form (for INFO) followed by a CAT
                    // chunk wrapping multiple FORM XMID sub-files.
                    guard let catStart = findCat(after: outerBody + outerSize - 4, in: data) else {
                        throw DecodeError.missingChunk("CAT ")
                    }
                    return try decodeCat(data, at: catStart)
                case "XMID":
                    // Single-track FORM XMID.
                    let track = try decodeTrack(data, start: outerBody, end: outerBody + outerSize - 4)
                    return Song(tracks: [track])
                default:
                    throw DecodeError.notIff
                }
            }

            private static func decodeCat(_ data: Data, at offset: Int) throws -> Song {
                // `CAT ` chunk: tag + u32 size + "XMID" + sub-forms.
                let tag = readFourCC(data, at: offset)
                guard tag == "CAT " else { throw DecodeError.missingChunk("CAT ") }
                let size = Int(readU32BE(data, at: offset + 4))
                guard readFourCC(data, at: offset + 8) == "XMID" else {
                    throw DecodeError.missingChunk("XMID")
                }
                var cursor = offset + 12
                let end = offset + 8 + size
                var tracks: [Track] = []
                while cursor + 8 <= end {
                    let formTag = readFourCC(data, at: cursor)
                    let formSize = Int(readU32BE(data, at: cursor + 4))
                    let formBody = cursor + 8
                    if formTag == "FORM" {
                        let innerTag = readFourCC(data, at: formBody)
                        if innerTag == "XMID" {
                            let track = try decodeTrack(data, start: formBody + 4, end: formBody + formSize)
                            tracks.append(track)
                        }
                    }
                    let padded = formSize + (formSize & 1)
                    cursor = formBody + padded
                }
                return Song(tracks: tracks)
            }

            private static func findCat(after offset: Int, in data: Data) -> Int? {
                // Walk forward looking for a "CAT " tag. The multi-track layout
                // places the CAT immediately after the outer FORM XDIR body.
                var i = offset
                while i + 8 <= data.endIndex {
                    if readFourCC(data, at: i) == "CAT " { return i }
                    i += 1
                }
                return nil
            }

            private static func decodeTrack(_ data: Data, start: Int, end: Int) throws -> Track {
                var cursor = start
                var evnt: Data? = nil
                while cursor + 8 <= end {
                    let tag = readFourCC(data, at: cursor)
                    let size = Int(readU32BE(data, at: cursor + 4))
                    let body = cursor + 8
                    let next = body + size + (size & 1)
                    if tag == "EVNT" {
                        evnt = data.subdata(in: body..<(body + size))
                    }
                    cursor = next
                }
                guard let evnt else { throw DecodeError.missingChunk("EVNT") }
                let events = try parseEvents(evnt)
                return Track(events: events)
            }
        }

        // MARK: - EVNT stream parser

        public static func parseEvents(_ evnt: Data) throws -> [Event] {
            var cursor = evnt.startIndex
            let end = evnt.endIndex
            var currentTick: UInt32 = 0
            var pending: [Event] = []
            var out: [Event] = []

            func readVLQ() throws -> UInt32 {
                var value: UInt32 = 0
                while cursor < end {
                    let b = evnt[cursor]
                    cursor += 1
                    value = (value << 7) | UInt32(b & 0x7F)
                    if (b & 0x80) == 0 { return value }
                }
                throw DecodeError.truncated
            }

            while cursor < end {
                // Delay bytes (every byte < 0x80 before the next event).
                while cursor < end && evnt[cursor] < 0x80 {
                    currentTick += UInt32(evnt[cursor])
                    cursor += 1
                }
                if cursor >= end { break }
                let status = evnt[cursor]
                cursor += 1

                if status == 0xFF {
                    // Meta event.
                    guard cursor < end else { throw DecodeError.truncated }
                    let type = evnt[cursor]; cursor += 1
                    let len = try readVLQ()
                    let lenI = Int(len)
                    guard cursor + lenI <= end else { throw DecodeError.truncated }
                    let data = Array(evnt[cursor..<(cursor + lenI)])
                    cursor += lenI
                    var bytes: [UInt8] = [0xFF, type]
                    bytes.append(contentsOf: encodeVLQ(len))
                    bytes.append(contentsOf: data)
                    out.append(Event(tick: currentTick, bytes: bytes))
                    if type == 0x2F { break } // End of track.
                    continue
                }

                let highNibble = status >> 4
                switch highNibble {
                case 0x9: // Note On — XMI form with VLQ duration
                    guard cursor + 1 < end else { throw DecodeError.truncated }
                    let note = evnt[cursor]; cursor += 1
                    let vel = evnt[cursor]; cursor += 1
                    let duration = try readVLQ()
                    out.append(Event(tick: currentTick, bytes: [status, note, vel]))
                    pending.append(Event(tick: currentTick + duration,
                                         bytes: [0x80 | (status & 0x0F), note, 0]))
                case 0x8, 0xA, 0xB, 0xE:
                    guard cursor + 1 < end else { throw DecodeError.truncated }
                    out.append(Event(tick: currentTick, bytes: [status, evnt[cursor], evnt[cursor + 1]]))
                    cursor += 2
                case 0xC, 0xD:
                    guard cursor < end else { throw DecodeError.truncated }
                    out.append(Event(tick: currentTick, bytes: [status, evnt[cursor]]))
                    cursor += 1
                case 0xF:
                    // SysEx (0xF0) — copy until 0xF7.
                    if status == 0xF0 {
                        let len = try readVLQ()
                        let lenI = Int(len)
                        guard cursor + lenI <= end else { throw DecodeError.truncated }
                        var bytes: [UInt8] = [0xF0]
                        bytes.append(contentsOf: encodeVLQ(len))
                        bytes.append(contentsOf: evnt[cursor..<(cursor + lenI)])
                        cursor += lenI
                        out.append(Event(tick: currentTick, bytes: bytes))
                    } else {
                        throw DecodeError.unexpectedStatus(status, at: cursor - 1)
                    }
                default:
                    throw DecodeError.unexpectedStatus(status, at: cursor - 1)
                }
            }
            // Flush pending note-offs.
            out.append(contentsOf: pending)
            // XMI's EOT often fires before a note-off that's still sounding;
            // SMF requires EOT to be the last event. Strip any EOT here — the
            // SMF writer always appends its own at the true end of the track.
            out.removeAll(where: { $0.bytes.count >= 2 && $0.bytes[0] == 0xFF && $0.bytes[1] == 0x2F })
            out.sort { $0.tick < $1.tick }
            return out
        }

        // MARK: - Low-level helpers

        private static func readFourCC(_ data: Data, at offset: Int) -> String {
            guard offset + 4 <= data.endIndex else { return "" }
            let bytes = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
            return String(bytes: bytes, encoding: .ascii) ?? ""
        }

        private static func readU32BE(_ data: Data, at offset: Int) -> UInt32 {
            (UInt32(data[offset]) << 24)
                | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8)
                | UInt32(data[offset + 3])
        }

        internal static func encodeVLQ(_ value: UInt32) -> [UInt8] {
            if value == 0 { return [0] }
            var bytes: [UInt8] = []
            var v = value
            bytes.append(UInt8(v & 0x7F))
            v >>= 7
            while v > 0 {
                bytes.append(UInt8((v & 0x7F) | 0x80))
                v >>= 7
            }
            return Array(bytes.reversed())
        }
    }
}

// MARK: - SMF writer

enum SmfWriter {
    static func write(events: [Formats.Xmi.Event], ticksPerQuarter: UInt16) -> Data {
        var track = Data()

        // Default tempo meta if the source stream doesn't carry one: 500000 μs/quarter.
        let hasTempo = events.contains { $0.bytes.count >= 2 && $0.bytes[0] == 0xFF && $0.bytes[1] == 0x51 }
        if !hasTempo {
            track.append(0x00)
            track.append(contentsOf: [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])
        }

        var prevTick: UInt32 = 0
        var emittedEot = false
        for event in events {
            let delta = event.tick - prevTick
            prevTick = event.tick
            track.append(contentsOf: Formats.Xmi.encodeVLQ(delta))
            track.append(contentsOf: event.bytes)
            if event.bytes.count >= 3 && event.bytes[0] == 0xFF && event.bytes[1] == 0x2F {
                emittedEot = true
            }
        }
        if !emittedEot {
            track.append(0x00)
            track.append(contentsOf: [0xFF, 0x2F, 0x00])
        }

        var out = Data()
        out.append(contentsOf: Array("MThd".utf8))
        out.append(uint32BE: 6)
        out.append(uint16BE: 0)                 // format 0
        out.append(uint16BE: 1)                 // single track
        out.append(uint16BE: ticksPerQuarter)

        out.append(contentsOf: Array("MTrk".utf8))
        out.append(uint32BE: UInt32(track.count))
        out.append(track)
        return out
    }
}

private extension Data {
    mutating func append(uint16BE value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
    mutating func append(uint32BE value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
