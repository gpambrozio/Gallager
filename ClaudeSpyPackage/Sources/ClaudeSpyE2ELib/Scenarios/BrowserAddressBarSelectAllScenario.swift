import Foundation

/// E2E scenario: a real mouse click on the in-app browser's address bar
/// selects the whole URL and keeps it selected (issue #651).
///
/// **Issue:** #651. PR #641 added Safari-style select-all-on-focus for the
/// address bar via SwiftUI's `TextField` + `TextSelection`, but the selection
/// only held under keyboard or accessibility focus. On a real *mouse* click
/// AppKit's field editor set the caret from the click on mouse-up — after the
/// deferred selection — so the whole-URL selection flashed and was immediately
/// lost. `BrowserDownloadsAndErrorsScenario` focuses the bar with AX
/// (`macFocusElement`), which has no mouse tracking to override the selection,
/// so it never touched this path. This scenario drives a real `CGEvent` click
/// (`macCGClickElement`) instead — the path users actually hit.
///
/// **Scope — this is a positive end-to-end test, not a strict bug-gate.** The
/// original defect is a race between the deferred selection and the field
/// editor's mouse-up caret placement, and it does *not* reproduce under the
/// harness's synthesized click: `macCGClickElement` posts mouse-down, sleeps
/// ~50 ms, then mouse-up, and that gap lets the old deferred `Task` land the
/// selection *after* the caret, so the pre-fix build passes this same scenario
/// (verified by running it against the reverted `TextField` implementation).
/// The fix is correct by construction — it selects all *after*
/// `super.mouseDown` returns (i.e. after the tracking loop and caret
/// placement), independent of timing — so this scenario's value is proving the
/// mouse-driven select-all path works end to end, and guarding against gross
/// regressions of it.
///
/// No page server is needed: the tab opens to a dead port, the navigation
/// fails, and the browser keeps the failed URL in the bar (Safari-like). The
/// URL field sits *above* the error overlay, so it stays clickable. Every
/// assertion is scoped to the field itself
/// (`.allOf([.anyTextMatches("URL"), …])`) so the copy of the failed URL that
/// the error page also renders can't mask the result.
///
/// Flow:
/// 1. Render an OSC 8 link to `http://127.0.0.1:9899/` (nothing listening) and
///    open it "In App" → error page, and the bar keeps the failed URL.
/// 2. A first real mouse click selects the whole URL; typing over it replaces
///    it, so the field no longer contains the dead-port token `9899`. Had the
///    click not kept the selection, the caret would sit past the text and the
///    keystrokes would append, leaving `9899` in the field.
/// 3. A second click (field already focused) positions the caret past the
///    short text instead of re-selecting, so the next keystrokes append and
///    `cleared` survives.
public enum BrowserAddressBarSelectAllScenario {
    /// Drift-tolerant click inside the large OSC 8 block painted by
    /// `link_block.py` — same coordinates as the other terminal-link browser
    /// scenarios (window pinned at (10, 10), 1_200×700).
    private static let terminalLinkX: Double = 400
    private static let terminalLinkY: Double = 200

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Browser Address Bar Select All",
        tags: ["browser", "macos-only"]
    ) {
        // ── Setup: render an OSC 8 link to a dead-port URL ────────────
        TestStep.log("Setup: render an OSC 8 link block pointing at a dead port")
        TestStep.injectScript(name: "link_block.py")
        TestStep.tmuxCreateSession(name: "selectall", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "selectall:0")
        TestStep.tmuxStorePaneId(target: "selectall:0", storeAs: "selectallPane")
        Shortcut.tmuxRunCommand(
            target: "selectall:0",
            command: "python3 $TMPDIR/link_block.py 'http://127.0.0.1:9899/'"
        )
        TestStep.wait(seconds: 1)

        // ── 1. Open the URL as a browser tab (dead port → error page) ─
        TestStep.log("Phase 1: Open the link In App → error page, the bar keeps the failed URL")
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        TestStep.macWaitForElement(titled: "selectall", timeout: 5)
        TestStep.macClickButton(titled: "selectall")
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-${selectallPane}"), .valueContains("OPEN-LINK-1")]),
            timeout: 10
        )
        TestStep.macClickAtPoint(x: terminalLinkX, y: terminalLinkY)
        TestStep.macWaitForElement(titled: "Open this link?", timeout: 5)
        TestStep.macClickButton(titled: "In App")
        TestStep.macWaitForElement(titled: "This page could not be loaded", timeout: 10)
        // Let the error page settle so the URL bar shows the failed URL.
        TestStep.wait(seconds: 1)

        // ── 2. A real mouse click selects the whole URL ───────────────
        TestStep.log("Phase 2: A real mouse click selects the whole URL (issue #651)")
        TestStep.macCGClickElement(query: .anyTextMatches("URL"))
        // The select-all lands a runloop turn after the field editor's
        // mouse-up (that late caret placement is exactly what used to wipe it).
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-address-bar-click-selects-all")
        TestStep.macType(text: "cleared")
        // Proof the click kept the selection: typing replaced the whole URL,
        // so the field no longer contains the dead-port token. Scoped to the
        // field (label "URL") so the error page's copy of the failed URL —
        // which still reads `9899` — can't keep this query alive.
        TestStep.macWaitForElementQueryToDisappear(
            .allOf([.anyTextMatches("URL"), .valueContains("9899")]),
            timeout: 5
        )

        // ── 3. A second click positions the caret (no re-select) ──────
        TestStep.log("Phase 3: Clicking the focused field again positions the caret, not select-all")
        TestStep.macCGClickElement(query: .anyTextMatches("URL"))
        TestStep.macType(text: "-suffix")
        // The second click didn't re-select, so the keystrokes appended and
        // the earlier text survives in the field.
        TestStep.macWaitForElementQuery(
            .allOf([.anyTextMatches("URL"), .valueContains("cleared")]),
            timeout: 5
        )
    }
}
