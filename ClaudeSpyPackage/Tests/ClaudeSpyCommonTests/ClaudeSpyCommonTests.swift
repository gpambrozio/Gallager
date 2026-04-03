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

// MARK: - stripKittyKeyboardProtocol

@Suite("TerminalResponseFilter.stripKittyKeyboardProtocol")
struct StripKittyKeyboardProtocolTests {
    @Test("Strips push mode ESC[>1u")
    func stripsPushMode() {
        let input = Data([0x1B, 0x5B, 0x3E, 0x31, 0x75]) // ESC [ > 1 u
        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(input)
        #expect(result.isEmpty)
    }

    @Test("Strips push mode with multiple flags ESC[>5u")
    func stripsPushModeMultipleFlags() {
        let input = Data([0x1B, 0x5B, 0x3E, 0x35, 0x75]) // ESC [ > 5 u
        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(input)
        #expect(result.isEmpty)
    }

    @Test("Strips pop mode ESC[<u")
    func stripsPopMode() {
        let input = Data([0x1B, 0x5B, 0x3C, 0x75]) // ESC [ < u
        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(input)
        #expect(result.isEmpty)
    }

    @Test("Strips pop mode with count ESC[<2u")
    func stripsPopModeWithCount() {
        let input = Data([0x1B, 0x5B, 0x3C, 0x32, 0x75]) // ESC [ < 2 u
        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(input)
        #expect(result.isEmpty)
    }

    @Test("Strips query mode ESC[?u")
    func stripsQueryMode() {
        let input = Data([0x1B, 0x5B, 0x3F, 0x75]) // ESC [ ? u
        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(input)
        #expect(result.isEmpty)
    }

    @Test("Strips set flags mode ESC[=1;2u")
    func stripsSetFlags() {
        let input = Data([0x1B, 0x5B, 0x3D, 0x31, 0x3B, 0x32, 0x75]) // ESC [ = 1 ; 2 u
        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(input)
        #expect(result.isEmpty)
    }

    @Test("Strips kitty sequence embedded in surrounding data")
    func stripsEmbeddedKitty() {
        var input = Data("hello".utf8)
        input.append(contentsOf: [0x1B, 0x5B, 0x3E, 0x31, 0x75]) // ESC [ > 1 u
        input.append(Data("world".utf8))

        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(input)
        #expect(result == Data("helloworld".utf8))
    }

    @Test("Strips multiple kitty sequences")
    func stripsMultipleKittySequences() {
        var input = Data([0x1B, 0x5B, 0x3E, 0x31, 0x75]) // ESC [ > 1 u (push)
        input.append(Data("text".utf8))
        input.append(contentsOf: [0x1B, 0x5B, 0x3C, 0x75]) // ESC [ < u (pop)

        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(input)
        #expect(result == Data("text".utf8))
    }

    @Test("Preserves normal data without ESC")
    func preservesNormalData() {
        let input = Data("normal terminal output".utf8)
        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(input)
        #expect(result == input)
    }

    @Test("Preserves other ESC sequences")
    func preservesOtherEscapeSequences() {
        // ESC [ 3 1 m (red foreground) should pass through
        let input = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D])
        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(input)
        #expect(result == input)
    }

    @Test("Preserves DEC private mode sequences")
    func preservesDECPrivateMode() {
        // ESC [ ? 25 h (show cursor) — ? prefix but final byte is 'h', not 'u'
        let input = Data([0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68])
        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(input)
        #expect(result == input)
    }

    @Test("Preserves DA queries with > prefix")
    func preservesSecondaryDAQuery() {
        // ESC [ > c (secondary DA query) — > prefix but final byte is 'c', not 'u'
        let input = Data([0x1B, 0x5B, 0x3E, 0x63])
        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(input)
        #expect(result == input)
    }

    @Test("Handles empty data")
    func handlesEmptyData() {
        let result = TerminalResponseFilter.stripKittyKeyboardProtocol(Data())
        #expect(result.isEmpty)
    }
}

// MARK: - isMouseEscapeSequence

@Suite("TerminalResponseFilter.isMouseEscapeSequence")
struct IsMouseEscapeSequenceTests {
    @Test("Detects SGR mouse press: ESC[<0;42;10M")
    func detectsSGRMousePress() {
        // ESC [ < 0 ; 4 2 ; 1 0 M
        let data: [UInt8] = [0x1B, 0x5B, 0x3C, 0x30, 0x3B, 0x34, 0x32, 0x3B, 0x31, 0x30, 0x4D]
        #expect(TerminalResponseFilter.isMouseEscapeSequence(data[...]))
    }

    @Test("Detects SGR mouse release: ESC[<0;42;10m")
    func detectsSGRMouseRelease() {
        // ESC [ < 0 ; 4 2 ; 1 0 m
        let data: [UInt8] = [0x1B, 0x5B, 0x3C, 0x30, 0x3B, 0x34, 0x32, 0x3B, 0x31, 0x30, 0x6D]
        #expect(TerminalResponseFilter.isMouseEscapeSequence(data[...]))
    }

    @Test("Detects SGR mouse motion: ESC[<32;200;100M")
    func detectsSGRMouseMotion() {
        // ESC [ < 3 2 ; 2 0 0 ; 1 0 0 M
        let data: [UInt8] = [0x1B, 0x5B, 0x3C, 0x33, 0x32, 0x3B, 0x32, 0x30, 0x30, 0x3B, 0x31, 0x30, 0x30, 0x4D]
        #expect(TerminalResponseFilter.isMouseEscapeSequence(data[...]))
    }

    @Test("Detects SGR scroll up: ESC[<64;1;1M")
    func detectsSGRScrollUp() {
        // ESC [ < 6 4 ; 1 ; 1 M
        let data: [UInt8] = [0x1B, 0x5B, 0x3C, 0x36, 0x34, 0x3B, 0x31, 0x3B, 0x31, 0x4D]
        #expect(TerminalResponseFilter.isMouseEscapeSequence(data[...]))
    }

    @Test("Detects X10 normal mouse: ESC[M followed by 3 bytes")
    func detectsX10NormalMouse() {
        // ESC [ M (button) (col) (row)
        let data: [UInt8] = [0x1B, 0x5B, 0x4D, 0x20, 0x21, 0x22]
        #expect(TerminalResponseFilter.isMouseEscapeSequence(data[...]))
    }

    @Test("Rejects SGR with wrong terminator: ESC[<0;42;10c")
    func rejectsSGRWrongTerminator() {
        // ESC [ < 0 ; 4 2 ; 1 0 c — 'c' is not 'M' or 'm', 10+ bytes
        let data: [UInt8] = [0x1B, 0x5B, 0x3C, 0x30, 0x3B, 0x34, 0x32, 0x3B, 0x31, 0x30, 0x63]
        #expect(!TerminalResponseFilter.isMouseEscapeSequence(data[...]))
    }

    @Test("Rejects too-short SGR sequence")
    func rejectsTooShortSGR() {
        // ESC [ < 0 M — only 5 bytes, minimum is 10
        let data: [UInt8] = [0x1B, 0x5B, 0x3C, 0x30, 0x4D]
        #expect(!TerminalResponseFilter.isMouseEscapeSequence(data[...]))
    }

    @Test("Rejects too-short X10 sequence (5 bytes)")
    func rejectsTooShortX10() {
        // ESC [ M + only 2 bytes
        let data: [UInt8] = [0x1B, 0x5B, 0x4D, 0x20, 0x21]
        #expect(!TerminalResponseFilter.isMouseEscapeSequence(data[...]))
    }

    @Test("Rejects regular CSI cursor up: ESC[1A")
    func rejectsRegularCSI() {
        let data: [UInt8] = [0x1B, 0x5B, 0x31, 0x41]
        #expect(!TerminalResponseFilter.isMouseEscapeSequence(data[...]))
    }

    @Test("Rejects data shorter than 3 bytes")
    func rejectsShortData() {
        let data: [UInt8] = [0x1B, 0x5B]
        #expect(!TerminalResponseFilter.isMouseEscapeSequence(data[...]))
    }

    @Test("Rejects empty data")
    func rejectsEmptyData() {
        let data: [UInt8] = []
        #expect(!TerminalResponseFilter.isMouseEscapeSequence(data[...]))
    }
}

// MARK: - isMouseMotionEvent

@Suite("TerminalResponseFilter.isMouseMotionEvent")
struct IsMouseMotionEventTests {
    @Test("Detects motion-only event (button=32)")
    func detectsMotionOnly() {
        // ESC [ < 32 ; 10 ; 5 m — motion, no button, release terminator
        let data: [UInt8] = [0x1B, 0x5B, 0x3C, 0x33, 0x32, 0x3B, 0x31, 0x30, 0x3B, 0x35, 0x6D]
        #expect(TerminalResponseFilter.isMouseMotionEvent(data[...]))
    }

    @Test("Detects motion+button event (button=34)")
    func detectsMotionWithButton() {
        // ESC [ < 34 ; 10 ; 5 M — motion + right button (32+2), press terminator
        let data: [UInt8] = [0x1B, 0x5B, 0x3C, 0x33, 0x34, 0x3B, 0x31, 0x30, 0x3B, 0x35, 0x4D]
        #expect(TerminalResponseFilter.isMouseMotionEvent(data[...]))
    }

    @Test("Rejects plain click (button=0)")
    func rejectsPlainClick() {
        // ESC [ < 0 ; 10 ; 5 M — left click, no motion bit
        let data: [UInt8] = [0x1B, 0x5B, 0x3C, 0x30, 0x3B, 0x31, 0x30, 0x3B, 0x35, 0x4D]
        #expect(!TerminalResponseFilter.isMouseMotionEvent(data[...]))
    }

    @Test("Rejects scroll up (button=64)")
    func rejectsScrollUp() {
        // ESC [ < 64 ; 10 ; 5 M — scroll up, no motion bit
        let data: [UInt8] = [0x1B, 0x5B, 0x3C, 0x36, 0x34, 0x3B, 0x31, 0x30, 0x3B, 0x35, 0x4D]
        #expect(!TerminalResponseFilter.isMouseMotionEvent(data[...]))
    }

    @Test("Rejects scroll down (button=65)")
    func rejectsScrollDown() {
        // ESC [ < 65 ; 10 ; 5 M — scroll down, no motion bit
        let data: [UInt8] = [0x1B, 0x5B, 0x3C, 0x36, 0x35, 0x3B, 0x31, 0x30, 0x3B, 0x35, 0x4D]
        #expect(!TerminalResponseFilter.isMouseMotionEvent(data[...]))
    }

    @Test("Rejects non-SGR input")
    func rejectsNonSGR() {
        // Regular CSI sequence, not mouse
        let data: [UInt8] = [0x1B, 0x5B, 0x41] // ESC [ A (cursor up)
        #expect(!TerminalResponseFilter.isMouseMotionEvent(data[...]))
    }

    @Test("Rejects empty data")
    func rejectsEmptyData() {
        let data: [UInt8] = []
        #expect(!TerminalResponseFilter.isMouseMotionEvent(data[...]))
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

    @Test("Detects kitty keyboard protocol response ESC[?1u")
    func detectsKittyProtocolResponse() {
        let data: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x75] // ESC [ ? 1 u
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
