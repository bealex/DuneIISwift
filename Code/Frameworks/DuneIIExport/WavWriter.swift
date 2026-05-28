import Foundation

/// Writes unsigned 8-bit mono PCM (as decoded from VOC) to a canonical RIFF/WAVE file. 8-bit WAV PCM
/// is unsigned (0x80 = silence), which matches VOC exactly, so samples pass through verbatim. Pure
/// Foundation (no audio framework needed).
public enum WavWriter {
    public static func encode(samples: [UInt8], sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 8
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataLength = samples.count

        func uint32(_ value: Int) -> [UInt8] {
            [ UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF) ]
        }

        func uint16(_ value: Int) -> [UInt8] {
            [ UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF) ]
        }

        var bytes: [UInt8] = []
        bytes += Array("RIFF".utf8)
        bytes += uint32(36 + dataLength)
        bytes += Array("WAVE".utf8)
        bytes += Array("fmt ".utf8)
        bytes += uint32(16)             // PCM fmt chunk size
        bytes += uint16(1)              // format = PCM
        bytes += uint16(channels)
        bytes += uint32(sampleRate)
        bytes += uint32(byteRate)
        bytes += uint16(blockAlign)
        bytes += uint16(bitsPerSample)
        bytes += Array("data".utf8)
        bytes += uint32(dataLength)
        bytes += samples
        return Data(bytes)
    }

    public static func write(samples: [UInt8], sampleRate: Int, to url: URL) throws {
        try encode(samples: samples, sampleRate: sampleRate).write(to: url)
    }
}
