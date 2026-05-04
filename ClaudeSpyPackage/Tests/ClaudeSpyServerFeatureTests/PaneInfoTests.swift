import ClaudeSpyNetworking
import Testing
@testable import ClaudeSpyServerFeature

@Suite("PaneInfo parsing")
struct PaneInfoTests {
    /// The production format string emitted by `TmuxService.refreshPanes`.
    /// Kept here to make the expected pipe-delimited layout explicit.
    private static let legacyLine = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1"
    /// Pre-color format with only `@gallager-description` at index 13.
    private static let preColorLine = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|My custom description"
    /// Current format: color at index 13, description at index 14+.
    private static let currentLine = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|blue|My custom description"

    @Test("Parses a full tmux line including color and description")
    func parsesCustomColorAndDescription() throws {
        let pane = try #require(PaneInfo(fromTmuxOutput: Self.currentLine))

        #expect(pane.paneId == "%5")
        #expect(pane.sessionName == "work")
        #expect(pane.windowIndex == 2)
        #expect(pane.paneIndex == 0)
        #expect(pane.customColor == .blue)
        #expect(pane.customDescription == "My custom description")
    }

    @Test("Empty color and description parse as nil")
    func emptyColorAndDescriptionParseAsNil() throws {
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1||"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customDescription == nil)
    }

    @Test("Color set without a description still parses")
    func colorWithoutDescriptionParses() throws {
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|red|"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == .red)
        #expect(pane.customDescription == nil)
    }

    @Test("Description set without a color still parses")
    func descriptionWithoutColorParses() throws {
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1||some description"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customDescription == "some description")
    }

    @Test("Unknown color values fall back to nil")
    func unknownColorParsesAsNil() throws {
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|chartreuse|My description"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customDescription == "My description")
    }

    @Test("Legacy pre-color lines still parse with color/description nil")
    func legacyLineIsBackwardCompatible() throws {
        let pane = try #require(PaneInfo(fromTmuxOutput: Self.legacyLine))
        #expect(pane.customColor == nil)
        #expect(pane.customDescription == nil)
        #expect(pane.isWindowActive)
    }

    @Test("Pre-color format puts the description in the color slot")
    func preColorLineParsesDescriptionAsColorSlot() throws {
        // The old format wrote description at index 13. Once the format shifts,
        // an old log line would land its description in the color slot. This
        // test pins the documented behaviour: such a value parses as
        // `customColor == nil` (unknown color name) and the description is
        // empty. Surfaces a reminder that historical logs don't survive the
        // format bump — the live tmux server always re-runs with the current
        // format string.
        let pane = try #require(PaneInfo(fromTmuxOutput: Self.preColorLine))
        #expect(pane.customColor == nil)
        #expect(pane.customDescription == nil)
    }

    @Test("Pipe characters inside the description are preserved")
    func pipesInDescriptionArePreserved() throws {
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1||foo | bar | baz"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customColor == nil)
        #expect(pane.customDescription == "foo | bar | baz")
    }
}
