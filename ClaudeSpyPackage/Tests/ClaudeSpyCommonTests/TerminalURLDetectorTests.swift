import Testing
@testable import ClaudeSpyCommon

@Suite("TerminalURLDetector.urlAt")
struct TerminalURLDetectorURLAtTests {
    // MARK: - OSC 8 trailing-whitespace bug

    /// Reproduces the bug where clicking on a cell that *only* contains
    /// trailing whitespace inside an OSC 8 payload range still opens the link.
    ///
    /// tmux's `capture-pane -e` extends OSC 8 hyperlink sequences across
    /// trailing whitespace to the end of the line. As a result, every cell
    /// to the right of the visible link text inherits the payload. Clicking
    /// any of those whitespace cells must NOT activate the link — only
    /// clicks landing on a visible (non-whitespace) glyph should.
    ///
    /// `detectURLs` already trims trailing whitespace; `urlAt` did not, which
    /// is why this test demonstrates the bug.
    @Test("urlAt on trailing whitespace within an OSC 8 payload range returns nil")
    func urlAtTrailingWhitespaceReturnsNil() {
        // Line: "file.txt        " — visible text occupies cols 0..7,
        // then 8 trailing spaces extend to col 15.
        let lineText = "file.txt        "
        let payload = ";file:///tmp/file.txt"

        // OSC 8 payload covers cols 0..15 (link text + tmux's whitespace
        // extension), matching what `capture-pane -e` produces.
        let urlAtClick: (Int) -> String? = { col in
            TerminalURLDetector.urlAt(
                col: col,
                row: 0,
                cols: 16,
                lineText: { row in row == 0 ? lineText : nil },
                cellPayload: { c, r in (r == 0 && c >= 0 && c <= 15) ? payload : nil },
                allowedSchemes: ["file", "http", "https", "ftp"]
            )
        }

        // Clicks on the visible link text should resolve to the URL.
        #expect(urlAtClick(0) == "file:///tmp/file.txt")
        #expect(urlAtClick(7) == "file:///tmp/file.txt")

        // Clicks on the trailing whitespace must NOT resolve to a URL.
        #expect(urlAtClick(8) == nil, "Click on first trailing-whitespace cell should not open the link")
        #expect(urlAtClick(12) == nil, "Click on mid-whitespace cell should not open the link")
        #expect(urlAtClick(15) == nil, "Click on last whitespace cell should not open the link")
    }

    @Test("urlAt on a fully visible OSC 8 link returns the URL across every text cell")
    func urlAtVisibleLinkReturnsURL() {
        let lineText = "click-me"
        let payload = ";file:///tmp/file.txt"

        for col in 0..<8 {
            let url = TerminalURLDetector.urlAt(
                col: col,
                row: 0,
                cols: 8,
                lineText: { row in row == 0 ? lineText : nil },
                cellPayload: { c, r in (r == 0 && c < 8) ? payload : nil },
                allowedSchemes: ["file", "http", "https", "ftp"]
            )
            #expect(url == "file:///tmp/file.txt", "Click at col \(col) on visible text should return URL")
        }
    }

    @Test("urlAt outside the OSC 8 payload range returns nil")
    func urlAtOutsidePayloadReturnsNil() {
        // OSC 8 payload only on cols 0..3 ("file"); cols 4..7 have no payload.
        let lineText = "fileNONE"
        let payload = ";file:///tmp/file.txt"

        let url = TerminalURLDetector.urlAt(
            col: 5,
            row: 0,
            cols: 8,
            lineText: { row in row == 0 ? lineText : nil },
            cellPayload: { c, r in (r == 0 && c < 4) ? payload : nil },
            allowedSchemes: ["file", "http", "https", "ftp"]
        )
        #expect(url == nil)
    }
}
