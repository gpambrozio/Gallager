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

// MARK: - stripDSRQueries

@Suite("TerminalResponseFilter.stripDSRQueries")
struct StripDSRQueriesTests {
    @Test("Strips CPR query ESC[6n")
    func stripsCPRQuery() {
        let input = Data([0x1B, 0x5B, 0x36, 0x6E]) // ESC [ 6 n
        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips DECXCPR query ESC[?6n")
    func stripsDECXCPRQuery() {
        let input = Data([0x1B, 0x5B, 0x3F, 0x36, 0x6E]) // ESC [ ? 6 n
        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips status query ESC[5n")
    func stripsStatusQuery() {
        let input = Data([0x1B, 0x5B, 0x35, 0x6E]) // ESC [ 5 n
        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips DEC private status query ESC[?15n")
    func stripsDECPrivateMultiDigitQuery() {
        // ESC [ ? 1 5 n
        let input = Data([0x1B, 0x5B, 0x3F, 0x31, 0x35, 0x6E])
        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips DSR query with multiple params ESC[?6;0n")
    func stripsMultiParamQuery() {
        // ESC [ ? 6 ; 0 n
        let input = Data([0x1B, 0x5B, 0x3F, 0x36, 0x3B, 0x30, 0x6E])
        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips DSR query embedded in surrounding data")
    func stripsEmbeddedDSR() {
        // "hello" + ESC[?6n + "world"
        var input = Data("hello".utf8)
        input.append(contentsOf: [0x1B, 0x5B, 0x3F, 0x36, 0x6E])
        input.append(Data("world".utf8))

        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result == Data("helloworld".utf8))
    }

    @Test("Strips multiple DSR queries from same chunk")
    func stripsMultipleDSRQueries() {
        // ESC[6n + "text" + ESC[?6n
        var input = Data([0x1B, 0x5B, 0x36, 0x6E])
        input.append(Data("text".utf8))
        input.append(contentsOf: [0x1B, 0x5B, 0x3F, 0x36, 0x6E])

        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result == Data("text".utf8))
    }

    @Test("Preserves data with no DSR queries")
    func preservesNormalData() {
        let input = Data("normal terminal output".utf8)
        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result == input)
    }

    @Test("Preserves other ESC sequences ending in 'n'")
    func preservesNonDSREscapeSequences() {
        // ESC [ ; ; n — empty params, no digits → not a DSR query (no param bytes)
        let input = Data([0x1B, 0x5B, 0x3B, 0x3B, 0x6E])
        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result == input)
    }

    @Test("Preserves SGR sequences (different terminator)")
    func preservesSGR() {
        // ESC [ 3 1 m (red foreground)
        let input = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D])
        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result == input)
    }

    @Test("Preserves DA query (different terminator)")
    func preservesDAQuery() {
        // ESC [ c — DA query, terminator 'c' not 'n'
        let input = Data([0x1B, 0x5B, 0x63])
        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result == input)
    }

    @Test("Handles empty data")
    func handlesEmptyData() {
        let result = TerminalResponseFilter.stripDSRQueries(Data())
        #expect(result.isEmpty)
    }

    @Test("Handles lone ESC at end of data")
    func handlesLoneESCAtEnd() {
        var input = Data("text".utf8)
        input.append(0x1B)
        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result == input)
    }

    @Test("Handles ESC[ without parameters or terminator")
    func handlesIncompleteCSI() {
        var input = Data("text".utf8)
        input.append(contentsOf: [0x1B, 0x5B])
        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result == input)
    }

    @Test("Handles ESC[? without parameters or terminator")
    func handlesIncompletePrivateCSI() {
        var input = Data("text".utf8)
        input.append(contentsOf: [0x1B, 0x5B, 0x3F])
        let result = TerminalResponseFilter.stripDSRQueries(input)
        #expect(result == input)
    }
}

// MARK: - stripDECRQMQueries

@Suite("TerminalResponseFilter.stripDECRQMQueries")
struct StripDECRQMQueriesTests {
    @Test("Strips DEC private DECRQM ESC[?2026$p (synchronized output)")
    func stripsSynchronizedOutputQuery() {
        // ESC [ ? 2 0 2 6 $ p
        let input = Data([0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x32, 0x36, 0x24, 0x70])
        let result = TerminalResponseFilter.stripDECRQMQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips standard DECRQM ESC[4$p")
    func stripsStandardDECRQM() {
        // ESC [ 4 $ p
        let input = Data([0x1B, 0x5B, 0x34, 0x24, 0x70])
        let result = TerminalResponseFilter.stripDECRQMQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips DECRQM with multi-digit param ESC[?1049$p")
    func stripsMultiDigitParam() {
        // ESC [ ? 1 0 4 9 $ p
        let input = Data([0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x24, 0x70])
        let result = TerminalResponseFilter.stripDECRQMQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips DECRQM embedded in surrounding data")
    func stripsEmbeddedDECRQM() {
        var input = Data("hello".utf8)
        input.append(contentsOf: [0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x32, 0x36, 0x24, 0x70])
        input.append(Data("world".utf8))

        let result = TerminalResponseFilter.stripDECRQMQueries(input)
        #expect(result == Data("helloworld".utf8))
    }

    @Test("Strips multiple DECRQM queries from same chunk")
    func stripsMultipleDECRQMQueries() {
        // ESC[?2026$p + "text" + ESC[4$p
        var input = Data([0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x32, 0x36, 0x24, 0x70])
        input.append(Data("text".utf8))
        input.append(contentsOf: [0x1B, 0x5B, 0x34, 0x24, 0x70])

        let result = TerminalResponseFilter.stripDECRQMQueries(input)
        #expect(result == Data("text".utf8))
    }

    @Test("Preserves DECRPM response (terminator y, not p)")
    func preservesDECRPMResponse() {
        // ESC [ ? 2 0 2 6 ; 2 $ y — DECRPM response, not a query
        let input = Data([0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x32, 0x36, 0x3B, 0x32, 0x24, 0x79])
        let result = TerminalResponseFilter.stripDECRQMQueries(input)
        #expect(result == input)
    }

    @Test("Preserves SGR sequences (no $ intermediate)")
    func preservesSGR() {
        // ESC [ 3 1 m
        let input = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D])
        let result = TerminalResponseFilter.stripDECRQMQueries(input)
        #expect(result == input)
    }

    @Test("Preserves DA query (no $ intermediate)")
    func preservesDAQuery() {
        let input = Data([0x1B, 0x5B, 0x63])
        let result = TerminalResponseFilter.stripDECRQMQueries(input)
        #expect(result == input)
    }

    @Test("Preserves DSR query (different terminator)")
    func preservesDSRQuery() {
        // ESC [ ? 6 n
        let input = Data([0x1B, 0x5B, 0x3F, 0x36, 0x6E])
        let result = TerminalResponseFilter.stripDECRQMQueries(input)
        #expect(result == input)
    }

    @Test("Preserves normal data without ESC")
    func preservesNormalData() {
        let input = Data("normal output with $p somewhere".utf8)
        let result = TerminalResponseFilter.stripDECRQMQueries(input)
        #expect(result == input)
    }

    @Test("Handles empty data")
    func handlesEmptyData() {
        let result = TerminalResponseFilter.stripDECRQMQueries(Data())
        #expect(result.isEmpty)
    }

    @Test("Handles ESC[?digits without trailing $p")
    func handlesIncompleteDECRQM() {
        // ESC [ ? 2 0 2 6 — no $p terminator
        let input = Data([0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x32, 0x36])
        let result = TerminalResponseFilter.stripDECRQMQueries(input)
        #expect(result == input)
    }

    @Test("Handles ESC[digits$ without trailing p")
    func handlesIncompleteIntermediate() {
        // ESC [ 4 $ — no final byte
        let input = Data([0x1B, 0x5B, 0x34, 0x24])
        let result = TerminalResponseFilter.stripDECRQMQueries(input)
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

// MARK: - stripOSCColorQueries

@Suite("TerminalResponseFilter.stripOSCColorQueries")
struct StripOSCColorQueriesTests {
    @Test("Strips OSC 11 background query (BEL-terminated)")
    func stripsBackgroundQueryBEL() {
        // ESC ] 1 1 ; ? BEL
        let input = Data([0x1B, 0x5D, 0x31, 0x31, 0x3B, 0x3F, 0x07])
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips OSC 11 background query (ST-terminated)")
    func stripsBackgroundQueryST() {
        // ESC ] 1 1 ; ? ESC \
        let input = Data([0x1B, 0x5D, 0x31, 0x31, 0x3B, 0x3F, 0x1B, 0x5C])
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips OSC 10 foreground query")
    func stripsForegroundQuery() {
        // ESC ] 1 0 ; ? BEL
        let input = Data([0x1B, 0x5D, 0x31, 0x30, 0x3B, 0x3F, 0x07])
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips OSC 12 cursor color query")
    func stripsCursorQuery() {
        // ESC ] 1 2 ; ? ESC \
        let input = Data([0x1B, 0x5D, 0x31, 0x32, 0x3B, 0x3F, 0x1B, 0x5C])
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips OSC 4 indexed palette query ESC]4;1;?")
    func stripsPaletteQuery() {
        // ESC ] 4 ; 1 ; ? BEL
        let input = Data([0x1B, 0x5D, 0x34, 0x3B, 0x31, 0x3B, 0x3F, 0x07])
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips multi-color query ESC]10;?;?;? (fg+bg+cursor)")
    func stripsMultiColorQuery() {
        // ESC ] 1 0 ; ? ; ? ; ? BEL
        let input = Data([0x1B, 0x5D, 0x31, 0x30, 0x3B, 0x3F, 0x3B, 0x3F, 0x3B, 0x3F, 0x07])
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result.isEmpty)
    }

    @Test("Strips OSC color query embedded in surrounding data")
    func stripsEmbeddedQuery() {
        var input = Data("before".utf8)
        input.append(contentsOf: [0x1B, 0x5D, 0x31, 0x31, 0x3B, 0x3F, 0x07]) // ESC]11;?BEL
        input.append(Data("after".utf8))

        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == Data("beforeafter".utf8))
    }

    @Test("Strips multiple OSC color queries from same chunk")
    func stripsMultipleQueries() {
        var input = Data([0x1B, 0x5D, 0x31, 0x30, 0x3B, 0x3F, 0x07]) // ESC]10;?BEL
        input.append(Data("x".utf8))
        input.append(contentsOf: [0x1B, 0x5D, 0x31, 0x31, 0x3B, 0x3F, 0x1B, 0x5C]) // ESC]11;?ST

        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == Data("x".utf8))
    }

    @Test("Preserves OSC 11 color *set* command (rgb value, no ?)")
    func preservesBackgroundSet() {
        // ESC ] 1 1 ; rgb:1a1a/1a1a/1a1a BEL — a set, not a query
        var input = Data([0x1B, 0x5D, 0x31, 0x31, 0x3B])
        input.append(Data("rgb:1a1a/1a1a/1a1a".utf8))
        input.append(0x07) // BEL
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == input)
    }

    @Test("Preserves OSC 4 palette *set* command")
    func preservesPaletteSet() {
        // ESC ] 4 ; 1 ; rgb:0000/0000/0000 BEL
        var input = Data([0x1B, 0x5D, 0x34, 0x3B, 0x31, 0x3B])
        input.append(Data("rgb:0000/0000/0000".utf8))
        input.append(0x07) // BEL
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == input)
    }

    @Test("Preserves OSC 0 title containing a ? (non-color code)")
    func preservesTitleWithQuestionMark() {
        // ESC ] 0 ; what? BEL — title, must not be stripped even with a '?'
        var input = Data([0x1B, 0x5D, 0x30, 0x3B])
        input.append(Data("what?".utf8))
        input.append(0x07) // BEL
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == input)
    }

    @Test("Preserves OSC 8 hyperlink with query string (? in URL)")
    func preservesHyperlinkWithQueryString() {
        // ESC ] 8 ; ; https://x.com/?a=b ESC \ — the ? is a URL query, not a color probe
        var input = Data([0x1B, 0x5D, 0x38, 0x3B, 0x3B])
        input.append(Data("https://x.com/?a=b".utf8))
        input.append(contentsOf: [0x1B, 0x5C])
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == input)
    }

    @Test("Preserves OSC 104 reset (code prefix 10 but not a color query)")
    func preservesResetCode() {
        // ESC ] 1 0 4 BEL — reset color; code 104 ≠ 10, no ? anyway
        let input = Data([0x1B, 0x5D, 0x31, 0x30, 0x34, 0x07])
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == input)
    }

    @Test("Preserves normal data without ESC")
    func preservesNormalData() {
        let input = Data("normal terminal output".utf8)
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == input)
    }

    @Test("Preserves other ESC sequences (CSI SGR)")
    func preservesOtherEscapeSequences() {
        // ESC [ 3 1 m (red foreground)
        let input = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D])
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == input)
    }

    @Test("Passes through an unterminated OSC color query intact")
    func passesThroughUnterminatedQuery() {
        // ESC ] 1 1 ; ? with no terminator (split across a read boundary).
        // Nothing is stripped so SwiftTerm eventually sees the full sequence.
        let input = Data([0x1B, 0x5D, 0x31, 0x31, 0x3B, 0x3F])
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == input)
    }

    @Test("Passes through OSC with a huge digit run (no Int overflow trap)")
    func handlesHugeCodeDigitRun() {
        // ESC ] 9…(×40) ; ? BEL — pane bytes are arbitrary (e.g. cat-ing
        // binary), so a long digit run must not trap on Int overflow.
        var input = Data([0x1B, 0x5D])
        input.append(contentsOf: Array(repeating: 0x39, count: 40))
        input.append(contentsOf: [0x3B, 0x3F, 0x07])
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == input)
    }

    @Test("CAN aborts the OSC so later unrelated output is preserved")
    func canAbortsOSCScan() {
        // ESC ] 11 ; CAN "real ? output" BEL — CAN (0x18) aborts the OSC
        // (xterm behavior), so the later ? and BEL belong to legitimate
        // output and nothing may be stripped.
        var input = Data([0x1B, 0x5D, 0x31, 0x31, 0x3B, 0x18])
        input.append(contentsOf: Data("real ? output".utf8))
        input.append(0x07)
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == input)
    }

    @Test("SUB aborts the OSC so later unrelated output is preserved")
    func subAbortsOSCScan() {
        // Same as CAN but with SUB (0x1A).
        var input = Data([0x1B, 0x5D, 0x31, 0x31, 0x3B, 0x1A])
        input.append(contentsOf: Data("real ? output".utf8))
        input.append(0x07)
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == input)
    }

    @Test("Handles empty data")
    func handlesEmptyData() {
        let result = TerminalResponseFilter.stripOSCColorQueries(Data())
        #expect(result.isEmpty)
    }

    @Test("Handles lone ESC at end of data")
    func handlesLoneESC() {
        var input = Data("text".utf8)
        input.append(0x1B)
        let result = TerminalResponseFilter.stripOSCColorQueries(input)
        #expect(result == input)
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

    @Test("Detects extended cursor position report (DECXCPR) ESC[?58;3;1R")
    func detectsExtendedCursorPositionReport() {
        // ESC [ ? 5 8 ; 3 ; 1 R — exactly the leaked form reported by users
        let data: [UInt8] = [0x1B, 0x5B, 0x3F, 0x35, 0x38, 0x3B, 0x33, 0x3B, 0x31, 0x52]
        #expect(TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Detects DEC private DECRPM response ESC[?2026;2$y")
    func detectsDECRPMPrivateResponse() {
        // ESC [ ? 2 0 2 6 ; 2 $ y — exactly the leaked form reported by users
        let data: [UInt8] = [0x1B, 0x5B, 0x3F, 0x32, 0x30, 0x32, 0x36, 0x3B, 0x32, 0x24, 0x79]
        #expect(TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Detects standard DECRPM response ESC[4;2$y")
    func detectsDECRPMStandardResponse() {
        // ESC [ 4 ; 2 $ y — non-private DECRPM
        let data: [UInt8] = [0x1B, 0x5B, 0x34, 0x3B, 0x32, 0x24, 0x79]
        #expect(TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Catch-all: any ESC[? sequence is a response")
    func catchAllDECPrivateResponses() {
        // Hypothetical future DEC private response with novel terminator
        let data: [UInt8] = [0x1B, 0x5B, 0x3F, 0x39, 0x39, 0x39, 0x40] // ESC [ ? 9 9 9 @
        #expect(TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Detects kitty keyboard protocol response ESC[?1u")
    func detectsKittyProtocolResponse() {
        let data: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x75] // ESC [ ? 1 u
        #expect(TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Detects OSC 11 background color report ESC]11;rgb:…")
    func detectsOSCBackgroundReport() {
        // ESC ] 1 1 ; r g b : 1 c 1 c … — leaked form reported in issue #669
        var data: [UInt8] = [0x1B, 0x5D, 0x31, 0x31, 0x3B]
        data.append(contentsOf: Array("rgb:1c1c/1c1c/1c1c".utf8))
        #expect(TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Detects OSC 10 foreground color report ESC]10;rgb:…")
    func detectsOSCForegroundReport() {
        var data: [UInt8] = [0x1B, 0x5D, 0x31, 0x30, 0x3B]
        data.append(contentsOf: Array("rgb:ffff/ffff/ffff".utf8))
        #expect(TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Detects OSC 4 indexed palette report ESC]4;1;rgb:…")
    func detectsOSCPaletteReport() {
        var data: [UInt8] = [0x1B, 0x5D, 0x34, 0x3B, 0x31, 0x3B]
        data.append(contentsOf: Array("rgb:0000/0000/0000".utf8))
        #expect(TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Rejects OSC title report ESC]0;… (non-color code)")
    func rejectsOSCTitle() {
        // ESC ] 0 ; hi — a title set, never a leaked color response
        let data: [UInt8] = [0x1B, 0x5D, 0x30, 0x3B, 0x68, 0x69]
        #expect(!TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Rejects OSC 104 (code prefix 10, not a color report)")
    func rejectsOSC104() {
        // ESC ] 1 0 4 ; — reset; code 104 ≠ 10
        let data: [UInt8] = [0x1B, 0x5D, 0x31, 0x30, 0x34, 0x3B]
        #expect(!TerminalResponseFilter.isTerminalResponse(data[...]))
    }

    @Test("Rejects OSC with a huge digit run (no Int overflow trap)")
    func rejectsHugeOSCCodeDigitRun() {
        // ESC ] 9…(×40) ; — reachable from paste, must not trap on overflow
        var data: [UInt8] = [0x1B, 0x5D]
        data.append(contentsOf: Array(repeating: 0x39, count: 40))
        data.append(0x3B)
        #expect(!TerminalResponseFilter.isTerminalResponse(data[...]))
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

// MARK: - TerminalURLDetector

@Suite("TerminalURLDetector regex detection")
struct TerminalURLDetectorRegexTests {
    @Test("Detects a simple plain-text URL surrounded by spaces")
    func detectsPlainURL() {
        let line = "see https://example.com for details"
        let urls = TerminalURLDetector.detectURLs(row: 0) { $0 == 0 ? line : nil }

        #expect(urls.count == 1)
        #expect(urls.first?.url == "https://example.com")
        #expect(urls.first?.startCol == 4)
        #expect(urls.first?.endCol == 4 + "https://example.com".utf16.count)
    }

    @Test("Stops URL match at NULL char from uninitialized terminal cells (issue #462)")
    func urlStopsAtNullChar() {
        // Reproduces issue #462: when a shell prompt theme writes right-aligned
        // content (e.g. exit code) via cursor positioning, the cells between
        // the typed URL and the right-aligned text are never written. SwiftTerm's
        // `BufferLine.translateToString` returns NULL chars (`\u{0}`, from
        // CharData.code == 0) for those cells. The URL regex must treat NULL
        // as a terminator — otherwise the match runs past the URL into the
        // right-aligned content, painting the underline across the whole line.
        let line = "$ git clone http://github.com/idonotexist/repo\u{0}\u{0}\u{0}\u{0}\u{0}130"
        let urls = TerminalURLDetector.detectURLs(row: 0) { $0 == 0 ? line : nil }

        #expect(urls.count == 1)
        #expect(urls.first?.url == "http://github.com/idonotexist/repo")
        let prefixCount = "$ git clone ".utf16.count
        let urlCount = "http://github.com/idonotexist/repo".utf16.count
        #expect(urls.first?.startCol == prefixCount)
        #expect(urls.first?.endCol == prefixCount + urlCount)
    }

    @Test("Stops URL match at any control character")
    func urlStopsAtControlChars() {
        // Cells written with literal control chars (rare but possible — e.g.
        // `cat -v` style output) should also terminate URL matching. Test a
        // representative sampling: SOH, BEL, BS, ESC, DEL.
        for control in ["\u{1}", "\u{7}", "\u{8}", "\u{1B}", "\u{7F}"] {
            let line = "x http://example.com\(control)trailing"
            let urls = TerminalURLDetector.detectURLs(row: 0) { $0 == 0 ? line : nil }

            #expect(urls.count == 1, "Failed for control char \\u{\(String(control.unicodeScalars.first!.value, radix: 16))}")
            #expect(urls.first?.url == "http://example.com")
        }
    }

    @Test("Allows tabs and existing whitespace to terminate URLs (regression check)")
    func urlStopsAtTabAndSpace() {
        let withTab = "x http://example.com\tfollowing"
        let urlsTab = TerminalURLDetector.detectURLs(row: 0) { $0 == 0 ? withTab : nil }
        #expect(urlsTab.count == 1)
        #expect(urlsTab.first?.url == "http://example.com")

        let withSpace = "x http://example.com following"
        let urlsSpace = TerminalURLDetector.detectURLs(row: 0) { $0 == 0 ? withSpace : nil }
        #expect(urlsSpace.count == 1)
        #expect(urlsSpace.first?.url == "http://example.com")
    }
}
