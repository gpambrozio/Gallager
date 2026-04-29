import Foundation

/// E2E scenario: Verify that clicking an OSC 8 `file://` hyperlink does NOT
/// open an in-app file tab when the host terminal has SGR mouse tracking
/// enabled (DECSET 1002 + 1006). This is the path TUI apps like Claude Code
/// take, and while they're tracking the mouse the click belongs to them —
/// the viewer must not intercept it.
///
/// **Why this scenario exists:** In mouse mode, the remote terminal app owns
/// the click stream. The viewer therefore stops underlining detected URLs
/// and forwards every click as a mouse SGR sequence. This scenario locks in
/// that behavior by clicking exactly where the link is rendered and
/// asserting the file tab never appears.
///
/// Flow:
/// 1. Enable SGR mouse tracking in the pane.
/// 2. Print an OSC 8 `file:///tmp/hello.txt` hyperlink.
/// 3. Click the link in the Gallager mirror.
/// 4. Verify no file tab appears (the click was forwarded to the shell as a
///    mouse event instead of being routed through `onOpenURL`).
public enum TerminalFileLinkMouseModeScenario {
    /// Same coordinates as `TerminalFileLinkScenario` — window at (10, 10),
    /// 1_200×700, sidebar 250, link on viewport row 1.
    private static let linkClickX: Double = 400
    private static let linkClickY: Double = 130

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal File Link Suppressed With Mouse Mode",
        tags: ["file-browser", "terminal", "links", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        TestStep.log("Setup: Create tmux session, enable SGR mouse mode, print OSC 8 link")
        TestStep.tmuxCreateSession(name: "termlink-mm", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "termlink-mm:0")

        // Single printf so the link lands on the same viewport row the click
        // coordinates target. The escape is button-event mouse tracking
        // (DECSET 1002) — enough to make SwiftTerm's `terminal.mouseMode`
        // non-`.off`, which is what the viewer uses to suppress URL handling.
        // SGR encoding (1006) is omitted purely to keep the typed command
        // short enough to avoid line wrapping at 100 columns; the suppression
        // logic only checks `mouseMode != .off`, not the encoding.
        Shortcut.tmuxRunCommand(
            target: "termlink-mm:0",
            command: #"printf '\e[?1002h\e]8;;file:///tmp/hello.txt\aclick-here-to-open-hello\e]8;;\a\n'"#
        )
        TestStep.wait(seconds: 1)

        // ── Launch app ───────────────────────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElement(titled: "termlink-mm", timeout: 5)
        TestStep.macClickButton(titled: "termlink-mm")
        TestStep.wait(seconds: 3)

        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("click-here-to-open-hello")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-mouse-mode-terminal-with-file-link")

        // ── Click the link → file tab must NOT open ──────────────
        TestStep.log("Click the file link with mouse mode active — file tab should not appear")
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)
        TestStep.wait(seconds: 2)

        // The tab was never created — `macWaitForElementToDisappear` succeeds
        // immediately when the element is absent, so this asserts the click
        // never reached `onOpenURL`.
        TestStep.macWaitForElementToDisappear(titled: "File tab: hello.txt", timeout: 3)
        TestStep.macScreenshot(label: "mac-mouse-mode-file-link-click-suppressed")

        // Tear down so we don't carry state into the next scenario.
        Shortcut.tmuxRunCommand(target: "termlink-mm:0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
