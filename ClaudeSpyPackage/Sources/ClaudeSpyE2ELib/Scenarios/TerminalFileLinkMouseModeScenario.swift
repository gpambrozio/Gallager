import Foundation

/// E2E scenario: Verify that clicking a `file://` link still opens an in-app
/// tab when the terminal application has SGR mouse tracking enabled (DECSET
/// 1002 + 1006). This is the path TUI apps like Claude Code take.
///
/// **Why this scenario exists:** The original `TerminalFileLinkScenario` runs
/// the click in plain zsh, where SwiftTerm's mouse mode is off. With mouse
/// mode on, our `mouseUp` overlay used to short-circuit URL detection and
/// forward the click to the terminal app, which then opened the file via its
/// own `open` call before our handler ran. The fix runs URL detection before
/// the mouse-mode short-circuit.
///
/// Flow:
/// 1. Enable SGR mouse tracking in the pane.
/// 2. Print an OSC 8 `file:///tmp/hello.txt` hyperlink.
/// 3. Click the link in the Gallager mirror.
/// 4. Verify the in-app file tab appears (proves the URL handler ran instead
///    of the click being delivered to the shell as a mouse event).
public enum TerminalFileLinkMouseModeScenario {
    /// Same coordinates as `TerminalFileLinkScenario` — window at (10, 10),
    /// 1_200×700, sidebar 250, link on viewport row 1.
    private static let linkClickX: Double = 400
    private static let linkClickY: Double = 130

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal File Link Opens In New Tab With Mouse Mode",
        tags: ["file-browser", "terminal", "links", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        TestStep.log("Setup: Create tmux session, enable SGR mouse mode, print OSC 8 link")
        TestStep.tmuxCreateSession(name: "termlink-mm", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "termlink-mm:0")

        // Single printf so the link lands on the same viewport row the click
        // coordinates target. The escape is button-event mouse tracking
        // (DECSET 1002) — enough to make SwiftTerm's `terminal.mouseMode`
        // non-`.off`, which is what triggers the click overlay's
        // `isMouseModeActive` branch. SGR encoding (1006) is omitted purely
        // to keep the typed command short enough to avoid line wrapping at
        // 100 columns; the bug being tested is independent of the encoding.
        Shortcut.tmuxRunCommand(
            target: "termlink-mm:0",
            command: #"printf '\e[?1002h\e]8;;file:///tmp/hello.txt\aclick-here-to-open-hello\e]8;;\a\n'"#
        )
        TestStep.wait(seconds: 1)

        // ── Launch app ───────────────────────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        TestStep.macWaitForElement(titled: "termlink-mm", timeout: 5)
        TestStep.macClickButton(titled: "termlink-mm")

        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("click-here-to-open-hello")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-mouse-mode-terminal-with-file-link")

        // ── Click the link → file tab opens ──────────────────────
        TestStep.log("Click the file link with mouse mode active")
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)

        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)
        TestStep.macWaitForElementQuery(
            .anyTextMatches("Hello, world!"),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-mouse-mode-file-tab-opened-from-terminal-click")

        // Tear down so we don't carry state into the next scenario.
        Shortcut.tmuxRunCommand(target: "termlink-mm:0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
