import ClaudeSpyNetworking
import Testing
@testable import ClaudeSpyServerFeature

@Suite("PaneInfo parsing")
struct PaneInfoTests {
    /// ASCII Unit Separator (U+001F) — the field delimiter the live tmux
    /// format produces. Pulled into a constant so the fixture strings stay
    /// legible.
    private static let sep = "\u{1F}"

    /// Legacy format with no color, emoji, or description columns.
    private static let legacyLine = "%5\(Self.sep)work\(Self.sep)2\(Self.sep)0\(Self.sep)zsh\(Self.sep)/tmp\(Self.sep)80\(Self.sep)24\(Self.sep)1\(Self.sep)Title\(Self.sep)d0c6,80x24\(Self.sep)main\(Self.sep)1"
    /// Pre-color format with only `@gallager-description` at index 13.
    private static let preColorLine = "%5\(Self.sep)work\(Self.sep)2\(Self.sep)0\(Self.sep)zsh\(Self.sep)/tmp\(Self.sep)80\(Self.sep)24\(Self.sep)1\(Self.sep)Title\(Self.sep)d0c6,80x24\(Self.sep)main\(Self.sep)1\(Self.sep)My custom description"
    /// Pre-emoji format: color at 13, description at 14+ (no emoji column).
    private static let preEmojiLine = "%5\(Self.sep)work\(Self.sep)2\(Self.sep)0\(Self.sep)zsh\(Self.sep)/tmp\(Self.sep)80\(Self.sep)24\(Self.sep)1\(Self.sep)Title\(Self.sep)d0c6,80x24\(Self.sep)main\(Self.sep)1\(Self.sep)blue\(Self.sep)My custom description"
    /// Current format: color at index 13, emoji at 14, description at 15.
    private static let currentLine = "%5\(Self.sep)work\(Self.sep)2\(Self.sep)0\(Self.sep)zsh\(Self.sep)/tmp\(Self.sep)80\(Self.sep)24\(Self.sep)1\(Self.sep)Title\(Self.sep)d0c6,80x24\(Self.sep)main\(Self.sep)1\(Self.sep)blue\(Self.sep)🚀\(Self.sep)My custom description"

    @Test("Parses a full tmux line including color, emoji, and description")
    func parsesCustomColorEmojiAndDescription() throws {
        let pane = try #require(PaneInfo(fromTmuxOutput: Self.currentLine))

        #expect(pane.paneId == "%5")
        #expect(pane.sessionName == "work")
        #expect(pane.windowIndex == 2)
        #expect(pane.paneIndex == 0)
        #expect(pane.customColor == .blue)
        #expect(pane.customEmoji == "🚀")
        #expect(pane.customDescription == "My custom description")
    }

    @Test("Empty color, emoji, and description parse as nil")
    func emptyOptionsParseAsNil() throws {
        let line = "%5\(Self.sep)work\(Self.sep)2\(Self.sep)0\(Self.sep)zsh\(Self.sep)/tmp\(Self.sep)80\(Self.sep)24\(Self.sep)1\(Self.sep)Title\(Self.sep)d0c6,80x24\(Self.sep)main\(Self.sep)1\(Self.sep)\(Self.sep)\(Self.sep)"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customEmoji == nil)
        #expect(pane.customDescription == nil)
    }

    @Test("Color set without an emoji or description still parses")
    func colorOnlyParses() throws {
        let line = "%5\(Self.sep)work\(Self.sep)2\(Self.sep)0\(Self.sep)zsh\(Self.sep)/tmp\(Self.sep)80\(Self.sep)24\(Self.sep)1\(Self.sep)Title\(Self.sep)d0c6,80x24\(Self.sep)main\(Self.sep)1\(Self.sep)red\(Self.sep)\(Self.sep)"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == .red)
        #expect(pane.customEmoji == nil)
        #expect(pane.customDescription == nil)
    }

    @Test("Emoji set without a color or description still parses")
    func emojiOnlyParses() throws {
        let line = "%5\(Self.sep)work\(Self.sep)2\(Self.sep)0\(Self.sep)zsh\(Self.sep)/tmp\(Self.sep)80\(Self.sep)24\(Self.sep)1\(Self.sep)Title\(Self.sep)d0c6,80x24\(Self.sep)main\(Self.sep)1\(Self.sep)\(Self.sep)🐛\(Self.sep)"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customEmoji == "🐛")
        #expect(pane.customDescription == nil)
    }

    @Test("Description set without a color or emoji still parses")
    func descriptionOnlyParses() throws {
        let line = "%5\(Self.sep)work\(Self.sep)2\(Self.sep)0\(Self.sep)zsh\(Self.sep)/tmp\(Self.sep)80\(Self.sep)24\(Self.sep)1\(Self.sep)Title\(Self.sep)d0c6,80x24\(Self.sep)main\(Self.sep)1\(Self.sep)\(Self.sep)\(Self.sep)some description"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customEmoji == nil)
        #expect(pane.customDescription == "some description")
    }

    @Test("Unknown color values fall back to nil but emoji and description still parse")
    func unknownColorParsesAsNil() throws {
        let line = "%5\(Self.sep)work\(Self.sep)2\(Self.sep)0\(Self.sep)zsh\(Self.sep)/tmp\(Self.sep)80\(Self.sep)24\(Self.sep)1\(Self.sep)Title\(Self.sep)d0c6,80x24\(Self.sep)main\(Self.sep)1\(Self.sep)chartreuse\(Self.sep)🚀\(Self.sep)My description"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customEmoji == "🚀")
        #expect(pane.customDescription == "My description")
    }

    @Test("Legacy pre-color lines still parse with color, emoji, and description nil")
    func legacyLineIsBackwardCompatible() throws {
        let pane = try #require(PaneInfo(fromTmuxOutput: Self.legacyLine))
        #expect(pane.customColor == nil)
        #expect(pane.customEmoji == nil)
        #expect(pane.customDescription == nil)
        #expect(pane.isWindowActive)
    }

    @Test("Pre-color format puts the description in the color slot")
    func preColorLineParsesDescriptionAsColorSlot() throws {
        let pane = try #require(PaneInfo(fromTmuxOutput: Self.preColorLine))
        #expect(pane.customColor == nil)
        #expect(pane.customEmoji == nil)
        #expect(pane.customDescription == nil)
    }

    @Test("Pre-emoji format puts the description in the emoji slot")
    func preEmojiLineParsesDescriptionAsEmojiSlot() throws {
        // Old format wrote description at index 14. After the format shifted
        // to add emoji at 14, an old log line would land the description in
        // the emoji slot. This test pins the documented behaviour: the value
        // gets read as the emoji and the description is empty. Historical
        // logs don't survive the format bump — the live tmux server always
        // re-runs with the current format string.
        let pane = try #require(PaneInfo(fromTmuxOutput: Self.preEmojiLine))
        #expect(pane.customColor == .blue)
        #expect(pane.customEmoji == "My custom description")
        #expect(pane.customDescription == nil)
    }

    @Test("Pipe characters inside the description are preserved")
    func pipesInDescriptionArePreserved() throws {
        // The format separator is U+001F, so `|` is just another character
        // and pipes appear verbatim in the parsed description.
        let line = "%5\(Self.sep)work\(Self.sep)2\(Self.sep)0\(Self.sep)zsh\(Self.sep)/tmp\(Self.sep)80\(Self.sep)24\(Self.sep)1\(Self.sep)Title\(Self.sep)d0c6,80x24\(Self.sep)main\(Self.sep)1\(Self.sep)\(Self.sep)\(Self.sep)foo | bar | baz"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customEmoji == nil)
        #expect(pane.customDescription == "foo | bar | baz")
    }

    @Test("Multi-character emoji parses as a single token")
    func multiCharacterEmojiParses() throws {
        // Family emoji is composed of multiple codepoints joined by ZWJs;
        // make sure the parse path doesn't truncate or mishandle it.
        let line = "%5\(Self.sep)work\(Self.sep)2\(Self.sep)0\(Self.sep)zsh\(Self.sep)/tmp\(Self.sep)80\(Self.sep)24\(Self.sep)1\(Self.sep)Title\(Self.sep)d0c6,80x24\(Self.sep)main\(Self.sep)1\(Self.sep)\(Self.sep)👨‍👩‍👧\(Self.sep)"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customEmoji == "👨‍👩‍👧")
    }

    @Test("Pane title containing a pipe does not shift later fields")
    func paneTitleWithPipeDoesNotShiftFields() throws {
        // Codex CLI sets `pane_title` to strings like
        // `[ ! ] Action Required | ios-amion-v2-2`, which embeds a literal
        // `|`. Splitting the format on `|` shifted every later field by one
        // and parked the emoji glyph in the description slot, so the sidebar
        // rendered "💖" as a description and showed nothing under the bell.
        let line = "%5\(Self.sep)work\(Self.sep)2\(Self.sep)0\(Self.sep)zsh\(Self.sep)/tmp\(Self.sep)80\(Self.sep)24\(Self.sep)1\(Self.sep)[ ! ] Action Required | ios-amion-v2-2\(Self.sep)d0c6,80x24\(Self.sep)main\(Self.sep)1\(Self.sep)\(Self.sep)💖\(Self.sep)"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.paneTitle == "[ ! ] Action Required | ios-amion-v2-2")
        #expect(pane.customColor == nil)
        #expect(pane.customEmoji == "💖")
        #expect(pane.customDescription == nil)
    }
}
