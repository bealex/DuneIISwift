import Foundation
import Testing

@testable import DuneIIFormats

/// The savegame container is the same IFF/FORM shape the `Iff.Reader` already handles: a `FORM`
/// wrapping a `SCEN` form-type marker followed by chunks (NAME, INFO, PLYR, UNIT, BLDG, "MAP ", …).
/// This confirms the reader handles that layout, including a 4CC with a trailing space.
@Suite("SaveContainer")
struct SaveContainerTests {
    @Test("reads a SCEN form with NAME and \"MAP \" chunks")
    func scen() throws {
        let save = IffBuilder.form(
            "SCEN",
            [
                IffBuilder.chunk("NAME", Array("My Save".utf8)),
                IffBuilder.chunk("MAP ", [ 0x01, 0x02, 0x03, 0x04 ]),
            ]
        )
        let reader = try Iff.Reader(save)
        #expect(reader.formType == "SCEN")
        #expect(reader.chunk("NAME") == Data("My Save".utf8))
        #expect(reader.chunk("MAP ") == Data([ 0x01, 0x02, 0x03, 0x04 ]))
    }
}
