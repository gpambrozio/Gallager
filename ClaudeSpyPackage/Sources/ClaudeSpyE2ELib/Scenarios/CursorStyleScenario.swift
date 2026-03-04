import Foundation

/// E2E scenario: Verify cursor style changes (DECSCUSR) render correctly
///
/// Sends DECSCUSR escape sequences (CSI Ps SP q) through the tmux pipe-pane
/// pipeline and verifies that the macOS mirror displays different cursor shapes:
/// steady block, steady underline, and steady bar.
///
/// Only tests "steady" (non-blinking) styles to avoid screenshot flakiness
/// from cursor blink animation timing.
///
/// This test verifies the fix for issue #184 where cursor style changes were
/// ignored because the CaretView always rendered as a hollow rectangle when
/// the TerminalView didn't have focus.
public enum CursorStyleScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Cursor Style Changes",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup ─────────────────────────────────────────────────────

        TestStep.log("Creating tmux session for cursor style test")
        TestStep.tmuxCreateSession(name: "cursor-test", width: 80, height: 24)

        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 900, height: 500)
        TestStep.macSetSidebarWidth(200)
        TestStep.wait(seconds: 1)

        TestStep.macClickButton(titled: "cursor-test:0.0")
        TestStep.wait(seconds: 2)

        // Clear screen and set a simple prompt
        TestStep.tmuxSendKeys(target: "cursor-test:0.0", keys: "clear", literal: true)
        TestStep.tmuxSendKeys(target: "cursor-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.5)

        // ── Steady Block (DECSCUSR 2) ─────────────────────────────────

        TestStep.log("Setting cursor to steady block (DECSCUSR 2)")
        TestStep.tmuxSendKeys(
            target: "cursor-test:0.0",
            keys: #"printf '\e[2 q' && echo 'Cursor: Steady Block'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "cursor-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 1)

        TestStep.macScreenshot(label: "cursor-steady-block")

        // ── Steady Underline (DECSCUSR 4) ─────────────────────────────

        TestStep.log("Setting cursor to steady underline (DECSCUSR 4)")
        TestStep.tmuxSendKeys(
            target: "cursor-test:0.0",
            keys: #"printf '\e[4 q' && echo 'Cursor: Steady Underline'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "cursor-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 1)

        TestStep.macScreenshot(label: "cursor-steady-underline")

        // ── Steady Bar (DECSCUSR 6) ───────────────────────────────────

        TestStep.log("Setting cursor to steady bar (DECSCUSR 6)")
        TestStep.tmuxSendKeys(
            target: "cursor-test:0.0",
            keys: #"printf '\e[6 q' && echo 'Cursor: Steady Bar'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "cursor-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 1)

        TestStep.macScreenshot(label: "cursor-steady-bar")

        // ── Reset to default ──────────────────────────────────────────

        TestStep.tmuxSendKeys(
            target: "cursor-test:0.0",
            keys: #"printf '\e[0 q'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "cursor-test:0.0", keys: "Enter")
    }
}
