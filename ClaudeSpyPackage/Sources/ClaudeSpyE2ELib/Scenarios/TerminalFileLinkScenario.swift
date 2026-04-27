import Foundation

/// E2E scenario: Verify that clicking a `file://` link in the terminal opens
/// the file in a new tab next to the file browser, instead of forwarding the
/// URL to the system default browser.
///
/// **Issue:** #402 — Intercept file open clicks and open in new tab.
///
/// Flow:
/// 1. Print an OSC 8 hyperlink whose URL is `file:///tmp/hello.txt` (the
///    in-memory fake file system resolves any path ending in `/hello.txt`).
/// 2. Click on the visible hyperlink text in the terminal — a real CGEvent
///    click, not a tmux-simulated event.
/// 3. Verify a new file tab appears with the file's name and content.
/// 4. Toggle the "Open clicked file links in a new tab" setting off.
/// 5. Click again and verify no new tab is created (the previous tab was
///    closed before this phase, so the absence proves the setting works).
///
/// The OSC 8 hyperlink text is wide and right-padded so we have enough
/// horizontal slack to land the click in the link span even with sub-pixel
/// font drift.
public enum TerminalFileLinkScenario {
    /// Screen coordinates of the visible hyperlink text. Computed for window
    /// position (10, 10), size 1_200×700, sidebar width 250.
    ///
    /// The OSC 8 hyperlink occupies an entire row (no prefix) starting at the
    /// terminal's first column on viewport row 1. Title bar + tab bar consume
    /// the first 100 px of the window vertically, and SF Mono 12 cells are
    /// ~14 pt tall. The terminal content area starts ~270 pt from the screen
    /// origin (window left + sidebar width + small inset).
    private static let linkClickX: Double = 400
    private static let linkClickY: Double = 130

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal File Link Opens In New Tab",
        tags: ["file-browser", "terminal", "links", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        TestStep.log("Setup: Create tmux session and print OSC 8 file link")
        TestStep.tmuxCreateSession(name: "termlink", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "termlink:0")

        // OSC 8 hyperlink format: \e]8;;<URL>\a<text>\e]8;;\a
        // The URL points at /tmp/hello.txt — the in-memory FS resolves any
        // path ending in /hello.txt to the fake hello.txt file. The visible
        // text fills most of the row (no prefix) so the click target is wide.
        Shortcut.tmuxRunCommand(
            target: "termlink:0",
            command: #"printf '\e]8;;file:///tmp/hello.txt\aclick-here-to-open-hello-txt-file\e]8;;\a\n'"#
        )
        TestStep.wait(seconds: 1)

        // ── Launch app ───────────────────────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElement(titled: "termlink", timeout: 5)
        TestStep.macClickButton(titled: "termlink")
        TestStep.wait(seconds: 3)

        // Wait for the link text to appear in the terminal's accessibility value
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("click-here-to-open-hello-txt-file")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-terminal-with-file-link")

        // ── Phase 1: Click the link → file tab opens ─────────────
        TestStep.log("Phase 1: Click the file link in the terminal")
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)
        TestStep.wait(seconds: 2)

        // The new tab carries the file name in its accessibility label.
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)
        // The file's content (from the in-memory fake) should be visible.
        TestStep.macWaitForElementQuery(
            .anyTextMatches("Hello, world!"),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-file-tab-opened-from-terminal-click")

        // Switch back to the terminal tab so the click target for Phase 2 is
        // the terminal again, not the file viewer.
        TestStep.macClickButton(titled: "termlink:0")
        TestStep.wait(seconds: 1)

        // Close the open file tab so its absence in Phase 2 actually proves
        // the setting blocked tab creation rather than reusing the existing one.
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Close file tab: hello.txt")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "File tab: hello.txt", timeout: 5)

        // ── Phase 2: Disable setting → click does NOT open a tab ─
        TestStep.log("Phase 2: Disable setting and verify clicks no longer open tabs")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macClickButton(titled: "When a file:// link is clicked in the terminal, open the file in a new tab instead of the system default browser")
        TestStep.wait(seconds: 1)
        TestStep.macCloseWindow(titled: "General")
        TestStep.wait(seconds: 1)

        // Re-select the pane after Settings closes so the terminal regains focus.
        TestStep.macClickButton(titled: "termlink:0")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("click-here-to-open-hello-txt-file")]),
            timeout: 10
        )

        // Click the link again. With the setting off, `onOpenURL` returns false
        // and `NSWorkspace.shared.open` is invoked on a non-existent path,
        // which silently no-ops — no new tab should appear.
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementToDisappear(titled: "File tab: hello.txt", timeout: 3)
        TestStep.macScreenshot(label: "mac-file-link-click-with-setting-off")

        // Tear down so we don't carry state into the next scenario.
        Shortcut.tmuxRunCommand(target: "termlink:0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
