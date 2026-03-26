import Foundation

/// E2E scenario: Scrollback gap when mirror terminal is smaller than tmux pane
///
/// Regression test for the scrollback gap bug. When a mirror terminal has fewer
/// rows than the tmux pane (e.g., 30-row mirror for a 50-row pane), scrolling up
/// used to reveal a gap of blank lines between scrollback content and visible
/// content. This was caused by `processCapturePaneForStreaming()` pushing
/// `height - 1` blank newlines (where height = tmux pane height, not mirror height).
///
/// Setup:
///   - Creates a tall tmux session (50 rows)
///   - Generates 200 numbered lines of scrollback via `seq 1 200`
///   - Launches macOS app with a SHORT window (~400px) so the mirror has ~20 rows
///   - Mirrors the pane, waits for content, then scrolls up to reveal scrollback
///
/// Expected: Continuous numbered lines with no blank gap in scrollback.
public enum ScrollbackGapScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Scrollback Gap Small Mirror",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup: tall tmux pane ────────────────────────────────────

        TestStep.log("Creating 50-row tmux session for scrollback gap test")
        TestStep.tmuxCreateSession(name: "scrollback-gap-test", width: 120, height: 50)

        // Generate numbered scrollback — 200 lines, only bottom ~50 visible
        TestStep.tmuxSendKeys(
            target: "scrollback-gap-test:0",
            keys: "seq 1 200",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "scrollback-gap-test:0", keys: "Enter")
        TestStep.wait(seconds: 2)

        // ── Launch macOS app with SHORT window ──────────────────────

        Shortcut.macOnlySetup
        // Short window: ~400px height gives ~20-25 terminal rows, well under 50
        TestStep.macResizeWindow(width: 1_200, height: 400)

        // ── Start mirroring ─────────────────────────────────────────

        TestStep.macClickButton(titled: "scrollback-gap-test:0")
        TestStep.wait(seconds: 3)

        // ── Capture: initial view (bottom of content) ───────────────

        TestStep.macScreenshot(label: "initial-bottom-view")

        // ── Scroll up to reveal scrollback ──────────────────────────

        TestStep.macScrollUp(pages: 3)
        TestStep.wait(seconds: 1)

        // Continuous numbered lines with no gap
        TestStep.macScreenshot(label: "scrolled-up-no-gap")

        // Scroll up more to see deeper into scrollback
        TestStep.macScrollUp(pages: 3)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "scrolled-up-deep")
    }
}
