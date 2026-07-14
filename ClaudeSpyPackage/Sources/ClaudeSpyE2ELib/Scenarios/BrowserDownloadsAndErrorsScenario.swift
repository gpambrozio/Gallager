import Foundation

/// E2E scenario: browser downloads bar, navigation error page, and
/// select-all-on-focus in the address bar.
///
/// **Issue:** #639 (better browser features).
///
/// A tiny Python HTTP server (`download_test_server.py`) runs on
/// `127.0.0.1:9877` and serves a deterministic "Download Test" page whose
/// body is one huge DOWNLOAD-REPORT link (drift-tolerant fixed-pixel click
/// target, same trick as `popup_test_server.py`). `/report` responds with
/// `Content-Disposition: attachment`, which the browser's new
/// `WKNavigationDelegate` converts into a `WKDownload`. Downloads are
/// redirected to a temp directory via `--downloads-dir` (exposed to steps as
/// `${downloadsDirPath}`) — writing to the real `~/Downloads` would trip a
/// TCC consent prompt the unattended app can't answer, wedging the download.
///
/// Flow:
/// 1. Open a browser tab by clicking an OSC 8 terminal link to the fixture
///    page (rendered as a large click-tolerant block by `link_block.py`,
///    same as `BrowserTabFromTerminalLinkScenario`) and picking "In App" on
///    the confirmation sheet → page loads, tab label becomes
///    "Browser tab: Download Test". (The "+" → "New Browser" menu is not
///    drivable via AXPress, so the link path is the reliable entry point.)
/// 2. Re-focus the address bar → the whole URL is selected (screenshot shows
///    the selection highlight).
/// 3. Type a dead-port URL (`http://127.0.0.1:9899/`, nothing listening —
///    note it must not be a WebKit *restricted* port like 1, which WebKit
///    blocks specially by committing about:blank instead of failing the
///    provisional navigation) — typing replaces the
///    selection — and submit → the error page appears ("This page could not
///    be loaded", connection refused, failed URL). The absence of any
///    element still containing `9877` proves the typed text *replaced* the
///    old URL rather than appending to it.
/// 4. "Try Again" re-attempts the failed URL (still refused → error page
///    persists). "Close" closes the browser tab entirely — the page behind
///    a failed navigation is often blank — returning to the origin terminal.
/// 5. Re-open the fixture page via the terminal link, then click the giant
///    download link → a downloads bar row appears with a completed
///    `report.txt` and a "Show in Finder" action; the saved file's contents
///    are asserted via `readFile` on `${downloadsDirPath}`.
/// 6. Click the link again → the second download dedupes to `report-2.txt`
///    (Safari-style collision naming; deterministic because the app wipes
///    the override directory on launch).
/// 7. Dismiss both rows → the downloads bar disappears.
public enum BrowserDownloadsAndErrorsScenario {
    /// Center of the giant DOWNLOAD-REPORT link. Window pinned at (10, 10),
    /// 1_200×700, sidebar 250: the web content spans x ∈ [260, 1_210] and
    /// starts below the tab strip + URL bar (~y 140). The link block fills
    /// 60% of the viewport height starting under the page heading, so
    /// (700, 400) lands comfortably inside it even if surrounding chrome
    /// shifts by a couple of rows.
    private static let downloadLinkX: Double = 700
    private static let downloadLinkY: Double = 400

    /// A click inside the large multi-line OSC 8 block painted by
    /// `link_block.py` — same drift-tolerant coordinates as
    /// `BrowserTabFromTerminalLinkScenario` (window pinned at (10, 10),
    /// 1_200×700).
    private static let terminalLinkX: Double = 400
    private static let terminalLinkY: Double = 200

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Browser Downloads And Errors",
        tags: ["browser", "downloads", "macos-only"]
    ) {
        // ── Setup: fixture server + clean ~/Downloads ─────────────
        TestStep.log("Setup: start download_test_server.py in a side tmux window")
        TestStep.injectScript(name: "download_test_server.py")

        TestStep.tmuxCreateSession(name: "downloads", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "downloads:0")

        // Run the server in a separate tmux window so its READY line doesn't
        // pollute the visible pane.
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "downloads", "-n", "server"])
        Shortcut.tmuxRunCommand(
            target: "downloads:server",
            command: "python3 $TMPDIR/download_test_server.py"
        )
        TestStep.wait(seconds: 2)
        TestStep.tmuxCapturePaneContent(target: "downloads:server", storeAs: "serverLog")
        TestStep.assertStoredContains(key: "serverLog", substring: "READY 9877")
        TestStep.tmuxCommand(arguments: ["select-window", "-t", "downloads:0"])

        // Render the fixture URL as a large OSC 8 block in window 0 so a
        // fixed-pixel click reliably opens it as a browser tab.
        TestStep.injectScript(name: "link_block.py")
        TestStep.tmuxStorePaneId(target: "downloads:0", storeAs: "downloadsPane")
        Shortcut.tmuxRunCommand(
            target: "downloads:0",
            command: "python3 $TMPDIR/link_block.py 'http://127.0.0.1:9877/'"
        )
        TestStep.wait(seconds: 1)

        // ── 1. Open a browser tab and load the fixture page ───────
        TestStep.log("Phase 1: Click the terminal link, open In App → fixture page loads")
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        TestStep.macWaitForElement(titled: "downloads", timeout: 5)
        TestStep.macClickButton(titled: "downloads")
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-${downloadsPane}"), .valueContains("OPEN-LINK-1")]),
            timeout: 10
        )
        TestStep.macClickAtPoint(x: terminalLinkX, y: terminalLinkY)
        TestStep.macWaitForElement(titled: "Open this link?", timeout: 5)
        TestStep.macClickButton(titled: "In App")
        TestStep.macWaitForElementQuery(.labelContains("Browser tab: Download Test"), timeout: 10)
        // Let the page finish painting so the screenshot shows the content.
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-browser-download-test-page")

        // ── 2. Focusing the address bar selects the whole URL ─────
        TestStep.log("Phase 2: Focusing the address bar selects the whole URL")
        TestStep.macFocusElement(titled: "URL")
        // The selection is applied a runloop turn after focus lands.
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-url-field-focus-selects-all")

        // ── 3. Typing replaces the selection; dead port → error page ─
        TestStep.log("Phase 3: Type a dead-port URL over the selection → error page")
        TestStep.macType(text: "http://127.0.0.1:9899/", pressReturn: true)
        TestStep.macWaitForElement(titled: "This page could not be loaded", timeout: 10)
        // Select-all proof: had the typed text been appended instead of
        // replacing, the URL field would still contain "9877".
        TestStep.macWaitForElementQueryToDisappear(.anyTextMatches("9877"), timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-error-page-connection-refused")

        // ── 4. Try Again keeps failing; Close closes the tab ──────
        TestStep.log("Phase 4: Try Again re-fails (port still dead); Close closes the tab")
        TestStep.macClickButton(titled: "Try Again")
        TestStep.macWaitForElement(titled: "This page could not be loaded", timeout: 10)

        // The button's visible title is "Close", but that substring also
        // matches the tab strip's "Close browser tab: …" / "Close window: …"
        // buttons (hidden ones are opacity-0, still in the AX tree) — target
        // the error page button by its exact `.help(...)` string instead.
        TestStep.macClickButton(titled: "Close this browser tab")
        TestStep.macWaitForElementToDisappear(titled: "This page could not be loaded", timeout: 5)
        // Close closes the whole tab; the tab came from a terminal link, so
        // the origin terminal window becomes selected again.
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-${downloadsPane}"), .valueContains("OPEN-LINK-1")]),
            timeout: 10
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-error-dismissed-tab-closed")

        // ── 5. Re-open the page; download via the attachment response ─
        TestStep.log("Phase 5: Reopen the fixture page, click the download link → completed row")
        TestStep.macClickAtPoint(x: terminalLinkX, y: terminalLinkY)
        TestStep.macWaitForElement(titled: "Open this link?", timeout: 5)
        TestStep.macClickButton(titled: "In App")
        TestStep.macWaitForElementQuery(.labelContains("Browser tab: Download Test"), timeout: 10)
        TestStep.wait(seconds: 1)
        TestStep.macClickAtPoint(x: downloadLinkX, y: downloadLinkY)
        TestStep.macWaitForElement(titled: "Show in Finder", timeout: 10)
        TestStep.macWaitForElement(titled: "report.txt", timeout: 5)
        TestStep.macScreenshot(label: "mac-download-completed-bar")

        // Assert the file actually landed in the (E2E-redirected) downloads
        // directory with the fixture body — file truth beats pixel truth.
        TestStep.readFile(path: "${downloadsDirPath}/report.txt", storeAs: "downloadedContent")
        TestStep.assertStoredContains(
            key: "downloadedContent",
            substring: "attachment download test contents"
        )

        // ── 6. Second download dedupes to report-2.txt ────────────
        TestStep.log("Phase 6: Download again → collision-free name report-2.txt")
        TestStep.macClickAtPoint(x: downloadLinkX, y: downloadLinkY)
        TestStep.macWaitForElement(titled: "report-2.txt", timeout: 10)
        TestStep.macScreenshot(label: "mac-download-dedup-second-row")

        // ── 7. Dismiss both rows → bar disappears ─────────────────
        TestStep.log("Phase 7: Clear both download rows → downloads bar disappears")
        TestStep.macClickButton(titled: "Clear download")
        TestStep.macClickButton(titled: "Clear download")
        TestStep.macWaitForElementToDisappear(titled: "Show in Finder", timeout: 5)
        TestStep.macScreenshot(label: "mac-downloads-bar-cleared")
    }
}
