import Foundation

/// E2E scenario: Verify cursor style (DECSCUSR) and visibility (DECTCEM) render correctly
///
/// Sends DECSCUSR escape sequences (CSI Ps SP q) through the tmux pipe-pane
/// pipeline and verifies that the macOS mirror displays different cursor shapes:
/// steady block, steady underline, and steady bar.
///
/// Also tests DECTCEM cursor visibility (CSI ?25l / ?25h) to verify that
/// hiding/showing the cursor in the remote pane is reflected in the mirror.
///
/// Only tests "steady" (non-blinking) styles to avoid screenshot flakiness
/// from cursor blink animation timing.
public enum CursorStyleScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Cursor Style Changes",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup ─────────────────────────────────────────────────────

        TestStep.log("Creating tmux session for cursor style test")
        TestStep.tmuxCreateSession(name: "cursor-test", width: 80, height: 24)

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 900, height: 500)

        TestStep.macClickButton(titled: "cursor-test")
        TestStep.wait(seconds: 2)

        // Clear screen and set a simple prompt
        Shortcut.tmuxRunCommand(target: "cursor-test:0", command: "clear")
        TestStep.wait(seconds: 0.5)

        // ── Steady Block (DECSCUSR 2) ─────────────────────────────────

        TestStep.log("Setting cursor to steady block (DECSCUSR 2)")
        Shortcut.tmuxRunCommand(
            target: "cursor-test:0",
            command: #"printf '\e[2 q' && echo 'Cursor: Steady Block'"#
        )
        TestStep.wait(seconds: 1)

        TestStep.macScreenshot(label: "mac-cursor-steady-block")

        // ── Steady Underline (DECSCUSR 4) ─────────────────────────────

        TestStep.log("Setting cursor to steady underline (DECSCUSR 4)")
        Shortcut.tmuxRunCommand(
            target: "cursor-test:0",
            command: #"printf '\e[4 q' && echo 'Cursor: Steady Underline'"#
        )
        TestStep.wait(seconds: 1)

        TestStep.macScreenshot(label: "mac-cursor-steady-underline")

        // ── Steady Bar (DECSCUSR 6) ───────────────────────────────────

        TestStep.log("Setting cursor to steady bar (DECSCUSR 6)")
        Shortcut.tmuxRunCommand(
            target: "cursor-test:0",
            command: #"printf '\e[6 q' && echo 'Cursor: Steady Bar'"#
        )
        TestStep.wait(seconds: 1)

        TestStep.macScreenshot(label: "mac-cursor-steady-bar")

        // ── Reset to default style ───────────────────────────────────

        Shortcut.tmuxRunCommand(
            target: "cursor-test:0",
            command: #"printf '\e[0 q'"#
        )
        TestStep.wait(seconds: 0.5)

        // ── Cursor Hidden (DECTCEM ?25l) ─────────────────────────────

        TestStep.log("Hiding cursor (DECTCEM ?25l)")
        Shortcut.tmuxRunCommand(
            target: "cursor-test:0",
            command: #"printf '\e[?25l' && echo 'Cursor: Hidden'"#
        )
        TestStep.wait(seconds: 1)

        TestStep.macScreenshot(label: "mac-cursor-hidden")

        // ── Cursor Shown (DECTCEM ?25h) ──────────────────────────────

        TestStep.log("Showing cursor (DECTCEM ?25h)")
        Shortcut.tmuxRunCommand(
            target: "cursor-test:0",
            command: #"printf '\e[?25h' && echo 'Cursor: Visible'"#
        )
        TestStep.wait(seconds: 1)

        TestStep.macScreenshot(label: "mac-cursor-visible")
    }
}
