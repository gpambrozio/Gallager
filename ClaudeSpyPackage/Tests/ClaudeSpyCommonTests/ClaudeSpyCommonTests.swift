import Foundation
import Testing
@testable import ClaudeSpyCommon

// MARK: - stripDAQueries

@Suite("TerminalResponseFilter.stripDAQueries")
struct StripDAQueriesTests {
    @Test("Strips primary DA query ESC[c")
    func stripsPrimaryDA() {
        let input = Data([0x1B, 0x5B, 0x63]) // ESC [ c
        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips primary DA query with explicit zero ESC[0c")
    func stripsPrimaryDAWithZero() {
        let input = Data([0x1B, 0x5B, 0x30, 0x63]) // ESC [ 0 c
        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips secondary DA query ESC[>c")
    func stripsSecondaryDA() {
        let input = Data([0x1B, 0x5B, 0x3E, 0x63]) // ESC [ > c
        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips secondary DA query with explicit zero ESC[>0c")
    func stripsSecondaryDAWithZero() {
        let input = Data([0x1B, 0x5B, 0x3E, 0x30, 0x63]) // ESC [ > 0 c
        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips tertiary DA query ESC[=c")
    func stripsTertiaryDA() {
        let input = Data([0x1B, 0x5B, 0x3D, 0x63]) // ESC [ = c
        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips tertiary DA query with explicit zero ESC[=0c")
    func stripsTertiaryDAWithZero() {
        let input = Data([0x1B, 0x5B, 0x3D, 0x30, 0x63]) // ESC [ = 0 c
        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips DA query embedded in surrounding data")
    func stripsEmbeddedDA() {
        // "hello" + ESC[c + "world"
        var input = Data("hello".utf8)
        input.append(contentsOf: [0x1B, 0x5B, 0x63])
        input.append(Data("world".utf8))

        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result == Data("helloworld".utf8))
    }

    @Test("Strips multiple DA queries from same chunk")
    func stripsMultipleDAQueries() {
        // ESC[c + "text" + ESC[>c
        var input = Data([0x1B, 0x5B, 0x63])
        input.append(Data("text".utf8))
        input.append(contentsOf: [0x1B, 0x5B, 0x3E, 0x63])

        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result == Data("text".utf8))
    }

    @Test("Preserves data with no DA queries")
    func preservesNormalData() {
        let input = Data("normal terminal output".utf8)
        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result == input)
    }

    @Test("Preserves other ESC sequences")
    func preservesOtherEscapeSequences() {
        // ESC [ 3 1 m (red foreground) should pass through
        let input = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D])
        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result == input)
    }

    @Test("Preserves DA response sequences (ESC[?...c)")
    func preservesDAResponses() {
        // ESC [ ? 6 5 ; 1 c — this is a DA *response*, not a query
        let input = Data([0x1B, 0x5B, 0x3F, 0x36, 0x35, 0x3B, 0x31, 0x63])
        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result == input)
    }

    @Test("Handles empty data")
    func handlesEmptyData() {
        let result = TerminalResponseFilter.stripDAQueries(Data())
        #expect(result.isEmpty)
    }

    @Test("Handles lone ESC at end of data")
    func handlesLoneESCAtEnd() {
        var input = Data("text".utf8)
        input.append(0x1B)
        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result == input)
    }

    @Test("Handles ESC[ without third byte at end")
    func handlesIncompleteCSI() {
        var input = Data("text".utf8)
        input.append(contentsOf: [0x1B, 0x5B])
        let result = TerminalResponseFilter.stripDAQueries(input)
        #expect(result == input)
    }
}

// MARK: - isTerminalResponse

@Suite("TerminalResponseFilter.isTerminalResponse")
struct IsTerminalResponseTests {
    @Test("Detects primary DA response ESC[?65;1;2c")
    func detectsPrimaryDA() {
        let data: [UInt8] = [0x1B, 0x5B, 0x3F, 0x36, 0x35, 0x3B, 0x31, 0x3B, 0x32, 0x63]
        #expect(TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Detects secondary DA response ESC[>...c")
    func detectsSecondaryDA() {
        let data: [UInt8] = [0x1B, 0x5B, 0x3E, 0x31, 0x3B, 0x32, 0x63]
        #expect(TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Detects cursor position report ESC[24;1R")
    func detectsCursorPositionReport() {
        let data: [UInt8] = [0x1B, 0x5B, 0x32, 0x34, 0x3B, 0x31, 0x52]
        #expect(TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Rejects regular CSI sequence")
    func rejectsRegularCSI() {
        // ESC [ 3 1 m (red foreground)
        let data: [UInt8] = [0x1B, 0x5B, 0x33, 0x31, 0x6D]
        #expect(!TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Rejects short data")
    func rejectsShortData() {
        let data: [UInt8] = [0x1B, 0x5B]
        #expect(!TerminalResponseFilter.isTerminalResponse(data[...]))
    }
}
