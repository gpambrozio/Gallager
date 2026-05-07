import ClaudeSpyNetworking
import Testing
@testable import ClaudeSpyServerFeature

@Suite("PaneInfo parsing")
struct PaneInfoTests {
    /// Legacy format with no color, emoji, or description columns.
    private static let legacyLine = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1"
    /// Pre-color format with only `@gallager-description` at index 13.
    private static let preColorLine = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|My custom description"
    /// Pre-emoji format: color at 13, description at 14+ (no emoji column).
    private static let preEmojiLine = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|blue|My custom description"
    /// Current format: color at index 13, emoji at 14, description at 15+.
    private static let currentLine = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|blue|🚀|My custom description"

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
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|||"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customEmoji == nil)
        #expect(pane.customDescription == nil)
    }

    @Test("Color set without an emoji or description still parses")
    func colorOnlyParses() throws {
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|red||"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == .red)
        #expect(pane.customEmoji == nil)
        #expect(pane.customDescription == nil)
    }

    @Test("Emoji set without a color or description still parses")
    func emojiOnlyParses() throws {
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1||🐛|"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customEmoji == "🐛")
        #expect(pane.customDescription == nil)
    }

    @Test("Description set without a color or emoji still parses")
    func descriptionOnlyParses() throws {
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|||some description"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customEmoji == nil)
        #expect(pane.customDescription == "some description")
    }

    @Test("Unknown color values fall back to nil but emoji and description still parse")
    func unknownColorParsesAsNil() throws {
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|chartreuse|🚀|My description"
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
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|||foo | bar | baz"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customEmoji == nil)
        #expect(pane.customDescription == "foo | bar | baz")
    }

    @Test("Multi-character emoji parses as a single token")
    func multiCharacterEmojiParses() throws {
        // Family emoji is composed of multiple codepoints joined by ZWJs;
        // make sure the parse path doesn't truncate or mishandle it.
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1||👨‍👩‍👧|"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customEmoji == "👨‍👩‍👧")
    }
}
