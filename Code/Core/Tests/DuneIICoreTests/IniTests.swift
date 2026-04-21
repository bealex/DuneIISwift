import Foundation
import Testing
@testable import DuneIICore

@Suite("Formats.Ini")
struct IniTests {
    @Test("minimal doc: two sections, case-insensitive lookup")
    func minimal() throws {
        let src = """
        [BASIC]
        LosePicture=LOSTBILD.WSA
        TimeOut=0

        [Atreides]
        Credits=1000
        Brain=Human
        """
        let doc = try Formats.Ini.Document.decode(Data(src.utf8))

        #expect(doc["BASIC"]?.value(forKey: "LosePicture") == "LOSTBILD.WSA")
        #expect(doc["basic"]?.value(forKey: "losepicture") == "LOSTBILD.WSA")
        #expect(doc["Atreides"]?.value(forKey: "Brain") == "Human")
    }

    @Test("comments and blank lines are skipped")
    func commentsAndBlanks() throws {
        let src = """
        ; leading comment
        ; another comment

        [BASIC]
        ; inline comment before a key
        Field=1300,1510

        [MAP]
        Seed=353
        """
        let doc = try Formats.Ini.Document.decode(Data(src.utf8))
        #expect(doc["BASIC"]?.value(forKey: "Field") == "1300,1510")
        #expect(doc["MAP"]?.value(forKey: "Seed") == "353")
    }

    @Test("CRLF line endings are supported")
    func crlf() throws {
        let src = "[BASIC]\r\nTimeOut=0\r\n\r\n[MAP]\r\nSeed=42\r\n"
        let doc = try Formats.Ini.Document.decode(Data(src.utf8))
        #expect(doc["BASIC"]?.value(forKey: "TimeOut") == "0")
        #expect(doc["MAP"]?.value(forKey: "Seed") == "42")
    }

    @Test("typed accessors: integerValue and integerListValue")
    func typedAccessors() throws {
        let src = """
        [MAP]
        Seed=353
        Field=1300,1510
        Bloom=abc
        """
        let doc = try Formats.Ini.Document.decode(Data(src.utf8))
        let map = doc["MAP"]!
        #expect(map.integerValue(forKey: "Seed") == 353)
        #expect(map.integerListValue(forKey: "Field") == [1300, 1510])
        #expect(map.integerValue(forKey: "Bloom") == nil)
        #expect(map.integerValue(forKey: "missing") == nil)
    }

    @Test("duplicate keys within a section: last assignment wins for typed lookup")
    func duplicateKeys() throws {
        let src = """
        [BASIC]
        Credits=500
        Credits=2000
        """
        let doc = try Formats.Ini.Document.decode(Data(src.utf8))
        #expect(doc["BASIC"]?.integerValue(forKey: "Credits") == 2000)
        // But insertion order in `.entries` must preserve both assignments.
        #expect(doc["BASIC"]?.entries.count == 2)
    }

    @Test("section entries preserve insertion order")
    func insertionOrder() throws {
        let src = """
        [UNITS]
        ID001=first
        ID002=second
        ID003=third
        """
        let doc = try Formats.Ini.Document.decode(Data(src.utf8))
        let keys = doc["UNITS"]?.entries.map { $0.key }
        #expect(keys == ["ID001", "ID002", "ID003"])
    }

    @Test("values with leading/trailing whitespace are trimmed")
    func whitespaceTrimmed() throws {
        let src = """
        [S]
        A=  hello world
        B=
        """
        let doc = try Formats.Ini.Document.decode(Data(src.utf8))
        #expect(doc["S"]?.value(forKey: "A") == "hello world")
        #expect(doc["S"]?.value(forKey: "B") == "")
    }

    @Test("keys outside any section are ignored, not an error")
    func keysOutsideSection() throws {
        let src = """
        orphan=ignored
        [S]
        real=kept
        """
        let doc = try Formats.Ini.Document.decode(Data(src.utf8))
        #expect(doc["S"]?.value(forKey: "real") == "kept")
        #expect(doc.sections.count == 1)
    }

    @Test("real SCENA001.INI exposes BASIC/MAP/UNITS/STRUCTURES sections")
    func realScenario() throws {
        guard let url = TestInstall.locate()?.appendingPathComponent("SCENARIO.PAK"),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try Formats.Pak.Archive(contentsOf: url)
        guard let body = archive.body(named: "SCENA001.INI") else { return }
        let doc = try Formats.Ini.Document.decode(body)

        #expect(doc["BASIC"] != nil)
        #expect(doc["MAP"] != nil)
        #expect(doc["UNITS"] != nil)
        #expect(doc["STRUCTURES"] != nil)
        #expect(doc["BASIC"]?.value(forKey: "LosePicture") == "LOSTBILD.WSA")
        #expect(doc["MAP"]?.integerValue(forKey: "Seed") == 353)
    }
}
