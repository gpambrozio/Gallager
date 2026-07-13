import Foundation

/// E2E scenario: after clicking into the loaded web page, a later mouse click
/// on the address bar must still select the whole URL (PR #652 follow-up).
///
/// User-reported regression on PR #652: the first click on the address bar
/// selects the whole URL, but once the WKWebView has taken keyboard focus (a
/// click anywhere on the page), the next click on the address bar reverts to
/// the old behavior — the selection flashes and collapses to a caret.
///
/// Unlike `BrowserAddressBarSelectAllScenario` (dead-port error page, webview
/// never focused), this scenario loads a real page from the relay server and
/// clicks *into* it between the two address-bar clicks, so the field-refocus
/// path crosses a WKWebView first-responder handoff.
///
/// **This one is a strict bug-gate: the race reproduces under the harness.**
/// With a loaded page, WebKit's main-thread activity drains the main queue
/// during the field editor's ~50 ms mouse-tracking loop, so a deferred
/// (focus-change-time) select-all fires mid-track and the mouse-up caret
/// placement wipes it — Phase 4 (and usually Phase 2) fail against the
/// pre-`pendingFocusSelectAll` build (verified 2026-07-13: the same scenario
/// failed at the Phase 4 typing assertion before the fix and passes after).
public enum BrowserAddressBarRefocusScenario {
    /// Drift-tolerant click inside the large OSC 8 block painted by
    /// `link_block.py` — same coordinates as the other terminal-link browser
    /// scenarios (window pinned at (10, 10), 1_200×700).
    private static let terminalLinkX: Double = 400
    private static let terminalLinkY: Double = 200
    /// A point comfortably inside the loaded page area of the browser tab
    /// (right pane, below the navigation bar) with the window pinned at
    /// (10, 10) and sized 1_200×700.
    private static let pageClickX: Double = 700
    private static let pageClickY: Double = 450

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Browser Address Bar Refocus",
        tags: ["browser", "macos-only"]
    ) {
        // ── Setup: real page served by the relay server ───────────────
        TestStep.log("Setup: render an OSC 8 link to the relay /health page")
        TestStep.startServer
        TestStep.verifyServerHealth
        TestStep.injectScript(name: "link_block.py")
        TestStep.tmuxCreateSession(name: "refocus", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "refocus:0")
        TestStep.tmuxStorePaneId(target: "refocus:0", storeAs: "refocusPane")
        Shortcut.tmuxRunCommand(
            target: "refocus:0",
            command: "python3 $TMPDIR/link_block.py 'http://127.0.0.1:8765/health'"
        )
        TestStep.wait(seconds: 1)

        // ── 1. Open the URL as a browser tab and let the page load ────
        TestStep.log("Phase 1: Open the link In App and let the page load")
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        TestStep.macWaitForElement(titled: "refocus", timeout: 5)
        TestStep.macClickButton(titled: "refocus")
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-${refocusPane}"), .valueContains("OPEN-LINK-1")]),
            timeout: 10
        )
        TestStep.macClickAtPoint(x: terminalLinkX, y: terminalLinkY)
        TestStep.macWaitForElement(titled: "Open this link?", timeout: 5)
        TestStep.macClickButton(titled: "In App")
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 5)
        TestStep.macWaitForElementQuery(.labelContains("Browser tab:"), timeout: 5)
        // Let the /health page finish loading so the webview has real content.
        TestStep.wait(seconds: 2)

        // ── 2. First click on the bar selects the whole URL ───────────
        TestStep.log("Phase 2: First mouse click on the address bar selects the whole URL")
        TestStep.macCGClickElement(query: .anyTextMatches("URL"))
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-first-click-selects-all")
        TestStep.macType(text: "cleared")
        // If the click kept the selection, typing replaced the whole URL and
        // the port token is gone from the field. If the selection got wiped
        // (the #651 race), the caret was merely positioned and "cleared" was
        // inserted into the existing URL, so "8765" survives and this wait
        // times out. Scoped to the field (label "URL") so other copies of the
        // URL (tab label, terminal) can't keep the query alive.
        TestStep.macWaitForElementQueryToDisappear(
            .allOf([.anyTextMatches("URL"), .valueContains("8765")]),
            timeout: 5
        )

        // ── 3. Click into the loaded page (webview takes focus) ───────
        TestStep.log("Phase 3: Click into the page so the webview takes keyboard focus")
        // Blurs the field (committing the typed "cleared" as mere field text —
        // no Return, so no navigation) and hands keyboard focus to the
        // WKWebView, which is what poisoned the next click's select-all.
        TestStep.macClickAtPoint(x: pageClickX, y: pageClickY)
        TestStep.wait(seconds: 1)

        // ── 4. Clicking the bar again must select the whole text ──────
        TestStep.log("Phase 4: Clicking the address bar again must select the whole text")
        TestStep.macCGClickElement(query: .anyTextMatches("URL"))
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-refocus-click-selects-all")
        TestStep.macType(text: "replaced")
        // Same replace-vs-append proof as Phase 2: if the refocusing click
        // kept the selection, "replaced" replaced "cleared" wholesale; if the
        // bug reproduced, the keystrokes appended and "cleared" survives.
        TestStep.macWaitForElementQueryToDisappear(
            .allOf([.anyTextMatches("URL"), .valueContains("cleared")]),
            timeout: 5
        )
        TestStep.macWaitForElementQuery(
            .allOf([.anyTextMatches("URL"), .valueContains("replaced")]),
            timeout: 5
        )
    }
}
