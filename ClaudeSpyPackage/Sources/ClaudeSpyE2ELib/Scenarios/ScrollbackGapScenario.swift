import Foundation

/// E2E scenario: Scrollback gap when mirror terminal is smaller than tmux pane
///
/// Regression test for scrollback gap bugs:
///
/// 1. Original bug: `processCapturePaneForStreaming()` pushed `height - 1` blank
///    newlines (where height = tmux pane height, not mirror height), causing gaps
///    in scrollback when mirror is smaller than pane.
///
/// 2. SU regression: Using CSI n S (Scroll Up) to push Part 1 content into the
///    scrollback buffer. SwiftTerm's cmdScrollUp deletes lines via splice instead
///    of pushing to scrollback, destroying ~height lines of content.
///
/// Setup:
///   - Creates a 40-row tmux session
///   - Generates 4 pages of visually distinct content (~160 lines total)
///   - Launches macOS app, mirrors the pane
///   - Scrolls up to reveal scrollback and checks for gaps
///
/// The 4 pages use very different content so that if ANY page is lost,
/// the screenshot will be obviously different and the test will fail.
public enum ScrollbackGapScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Scrollback Gap Small Mirror",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup: tmux pane with 4 pages of distinct content ───────

        TestStep.log("Creating 40-row tmux session for scrollback gap test")
        TestStep.tmuxCreateSession(name: "scrollback-gap-test", width: 120, height: 40)

        // Generate 4 pages of visually distinct content (~40 lines each = ~160 total).
        // Each page has a unique pattern so missing pages are immediately obvious
        // in screenshots.
        //
        // Page 1 (lines 1-40):   "AAAA..." rows
        // Page 2 (lines 41-80):  "####..." rows
        // Page 3 (lines 81-120): "~~~~..." rows
        // Page 4 (lines 121-160):">>>>" rows (this page is in the visible area)

        // Use printf to generate all 4 pages in a single command
        Shortcut.tmuxRunCommand(
            target: "scrollback-gap-test:0",
            command: "for i in $(seq 1 40); do printf 'PAGE1 %03d AAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n' $i; done; for i in $(seq 1 40); do printf 'PAGE2 %03d ############################\\n' $i; done; for i in $(seq 1 40); do printf 'PAGE3 %03d ~~~~~~~~~~~~~~~~~~~~~~~~~~~~\\n' $i; done; for i in $(seq 1 40); do printf 'PAGE4 %03d >>>>>>>>>>>>>>>>>>>>>>>>>>>>\\n' $i; done"
        )
        TestStep.wait(seconds: 3)

        // ── Launch macOS app ────────────────────────────────────────

        Shortcut.macOnlySetup

        // ── Start mirroring ─────────────────────────────────────────

        TestStep.macClickButton(titled: "scrollback-gap-test")
        TestStep.wait(seconds: 3)

        // ── Capture: initial view (bottom of content = PAGE4) ───────

        TestStep.macScreenshot(label: "mac-initial-bottom-view")

        // ── Scroll up to reveal PAGE3 ───────────────────────────────

        TestStep.macScrollUp(pages: 1)
        TestStep.wait(seconds: 1)

        // Should show PAGE3 content (~~~~ pattern)
        TestStep.macScreenshot(label: "mac-scrolled-up-page3")

        // ── Scroll up more to reveal PAGE2 ──────────────────────────

        TestStep.macScrollUp(pages: 1)
        TestStep.wait(seconds: 1)

        // Should show PAGE2 content (#### pattern)
        TestStep.macScreenshot(label: "mac-scrolled-up-page2")

        // ── Scroll up further to reveal PAGE1 ───────────────────────

        TestStep.macScrollUp(pages: 1)
        TestStep.wait(seconds: 1)

        // Should show PAGE1 content (AAAA pattern)
        TestStep.macScreenshot(label: "mac-scrolled-up-page1")
    }
}
