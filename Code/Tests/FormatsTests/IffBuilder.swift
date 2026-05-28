import Foundation

/// Builds IFF/FORM byte streams for synthetic decoder tests (ICN, EMC, SAVE). Mirrors the layout the
/// `Iff.Reader` expects: `"FORM"` + uint32 BE length + form type + chunks (4CC + uint32 BE length +
/// payload, padded to even).
enum IffBuilder {
    static func beUInt32(_ value: Int) -> [UInt8] {
        [ UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF) ]
    }

    static func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
        var out = Array(id.utf8)
        out += beUInt32(payload.count)
        out += payload
        if payload.count & 1 == 1 { out.append(0) }
        return out
    }

    static func form(_ formType: String, _ chunks: [[UInt8]]) -> Data {
        var body = Array(formType.utf8)
        for chunk in chunks { body += chunk }
        var out = Array("FORM".utf8)
        out += beUInt32(body.count)
        out += body
        return Data(out)
    }
}
