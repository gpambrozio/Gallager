import Testing
@testable import ClaudeSpyServerFeature

@Suite("PaneInfo parsing")
struct PaneInfoTests {
    /// The production format string emitted by `TmuxService.refreshPanes`.
    /// Kept here to make the expected pipe-delimited layout explicit.
    private static let legacyLine = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1"
    private static let extendedLine = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|My custom description"

    @Test("Parses a full tmux line including @gallager-description")
    func parsesCustomDescription() throws {
        let pane = try #require(PaneInfo(fromTmuxOutput: Self.extendedLine))

        #expect(pane.paneId == "%5")
        #expect(pane.sessionName == "work")
        #expect(pane.windowIndex == 2)
        #expect(pane.paneIndex == 0)
        #expect(pane.customDescription == "My custom description")
    }

    @Test("Empty @gallager-description parses as nil")
    func emptyDescriptionParsesAsNil() throws {
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customDescription == nil)
    }

    @Test("Legacy lines without the description component still parse")
    func legacyLineIsBackwardCompatible() throws {
        let pane = try #require(PaneInfo(fromTmuxOutput: Self.legacyLine))
        #expect(pane.customDescription == nil)
        #expect(pane.isWindowActive)
    }

    @Test("Pipe characters inside the description are preserved")
    func pipesInDescriptionArePreserved() throws {
        let line = "%5|work|2|0|zsh|/tmp|80|24|1|Title|d0c6,80x24|main|1|foo | bar | baz"
        let pane = try #require(PaneInfo(fromTmuxOutput: line))
        #expect(pane.customDescription == "foo | bar | baz")
    }
}
