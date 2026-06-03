import Foundation
import Testing

@testable import DuneIIFormats

@Suite("Ini")
struct IniTests {
    static let text = "[Basic]\r\nName=Test\r\nCredits=1500\r\n[MAP]\r\nField=10,20\r\n"

    @Test("section and key lookups are case-insensitive")
    func lookup() {
        let ini = Ini(text: IniTests.text)
        #expect(ini.string(section: "basic", key: "name") == "Test")
        #expect(ini.integer(section: "BASIC", key: "Credits") == 1500)
        #expect(ini.string(section: "MAP", key: "Field") == "10,20")
    }

    @Test("enumerates section names and keys in order")
    func enumeration() {
        let ini = Ini(text: IniTests.text)
        #expect(ini.sectionNames == [ "Basic", "MAP" ])
        #expect(ini.keys(section: "Basic") == [ "Name", "Credits" ])
    }

    @Test("missing key returns the default")
    func missing() {
        let ini = Ini(text: IniTests.text)
        #expect(ini.string(section: "Nope", key: "X") == nil)
        #expect(ini.integer(section: "Basic", key: "Missing", default: 7) == 7)
    }

    @Test("real install scenario INI parses")
    func realData() throws {
        guard let bytes = TestInstall.pakEntry("SCENARIO.PAK", matchingSuffix: ".INI") else { return }

        let ini = Ini(bytes)
        #expect(!ini.sectionNames.isEmpty)
    }
}
