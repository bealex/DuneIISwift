import Testing
import Foundation
@testable import DuneIIFormats

/// The Mentat help database decoder (`MENTAT<HOUSE>.ENG`): the `NAME` topic list + the char-pair-compressed
/// descriptions. Driven by the committed `Resources/Strings/MENTATH.ENG`.
@Suite("Mentat help")
struct MentatHelpTests {
    private func mentatData(_ name: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root.appendingPathComponent("Resources/Strings/\(name)"))
    }

    @Test("the decompressor expands the char-pair scheme (string.c couples table)")
    func decompress() {
        // " e" pair: high-bit byte 0x80 → couples[0]=' ', couples[16]='t' ⇒ " t"; a plain byte passes through.
        let bytes: [UInt8] = [0x80, UInt8(ascii: "X"), 0x00]
        #expect(MentatHelp.decompress(bytes, at: 0) == " tX")
    }

    @Test("MENTATH parses the topic list with sections, campaign gates, and descriptions")
    func parsesTopics() throws {
        let topics = try MentatHelp.topics(try mentatData("MENTATH.ENG"))
        #expect(topics.count > 40)

        // A structure topic: the Construction Yard, available from the first campaign, with parsed text.
        let cy = try #require(topics.first { $0.name == "Construction Yard" })
        #expect(cy.section == .structures)
        #expect(!cy.isHeader)
        #expect(cy.title == "Construction Yard")
        #expect(cy.wsa.lowercased() == "construc.wsa")
        #expect(cy.body.contains("construct other buildings"))

        // A vehicle topic with attribute lines.
        let tank = try #require(topics.first { $0.name == "Combat Tank" })
        #expect(tank.section == .vehicles)
        #expect(tank.campaign == 4)            // unlocks at campaignID+1 ≥ 4
        #expect(tank.attributes.contains { $0.contains("Mobility") })

        // A house lore topic.
        let house = try #require(topics.first { $0.name == "House Atreides" })
        #expect(house.section == .houses)
        #expect(house.body.contains("Caladan"))

        // Section headers are flagged (e.g. the "Structures" divider).
        #expect(topics.contains { $0.name == "Structures" && $0.isHeader })
    }
}
