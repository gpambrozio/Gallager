import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("SessionColor parsing")
struct SessionColorTests {
    @Test("Each canonical name parses to its case")
    func parsesCanonicalNames() {
        for color in SessionColor.allCases {
            #expect(SessionColor.parse(color.rawValue) == color)
        }
    }

    @Test("Parsing is case-insensitive")
    func parsingIsCaseInsensitive() {
        #expect(SessionColor.parse("Red") == .red)
        #expect(SessionColor.parse("BLUE") == .blue)
        #expect(SessionColor.parse("Yellow") == .yellow)
    }

    @Test("Aliases map to expected colors")
    func aliasesParse() {
        #expect(SessionColor.parse("violet") == .purple)
        #expect(SessionColor.parse("magenta") == .pink)
        #expect(SessionColor.parse("grey") == .gray)
    }

    @Test("Unknown values return nil")
    func unknownReturnsNil() {
        #expect(SessionColor.parse("chartreuse") == nil)
        #expect(SessionColor.parse("") == nil)
        #expect(SessionColor.parse("not-a-color") == nil)
    }

    @Test("Display name capitalises the first character")
    func displayNameIsCapitalised() {
        #expect(SessionColor.red.displayName == "Red")
        #expect(SessionColor.gray.displayName == "Gray")
    }

    @Test("Roundtrips through Codable")
    func roundtripsThroughCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for color in SessionColor.allCases {
            let data = try encoder.encode(color)
            let decoded = try decoder.decode(SessionColor.self, from: data)
            #expect(decoded == color)
        }
    }
}
