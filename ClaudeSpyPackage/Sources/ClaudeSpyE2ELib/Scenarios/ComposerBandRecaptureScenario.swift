import Foundation

/// E2E scenario: multi-row background band loses a line's background after
/// navigating away and back (#578).
///
/// Reproduces the bug reported in issue #578 where a Codex composer's
/// full-width gray background band renders correctly on first view but loses
/// the background on one or more of its lines after the session is navigated
/// away from and returned to. iTerm and the real terminal render the same pane
/// correctly, so the bug is specific to the app's mirror.
///
/// ## The bug
///
/// `tmux capture-pane -e` (without `-N`) trims trailing spaces at each line's
/// end. A *multi-row* background band is drawn with the bg setter on its first
/// row only — tmux's SGR state then carries the bg across line boundaries, so
/// the band's continuation rows are nothing but bg-colored spaces with no
/// setter of their own. Trimming erases those spaces, leaving the continuation
/// rows byte-identical to genuinely-blank rows. `processCapturePaneForStreaming`
/// then rebuilds each row independently with an SGR reset between rows, so the
/// continuation rows render with the default (black) background.
///
/// The first view renders correctly because the band is painted by the *live*
/// byte stream (the real escape sequences). Re-viewing the session rebuilds the
/// screen from `capture-pane`, which is where the background is lost.
///
/// ## The fix
///
/// Capture the visible area with `-N` (preserve trailing spaces without joining
/// wrapped lines) so the continuation rows keep their real bg spaces, and
/// restore the SGR state carried into each rebuilt row so those spaces inherit
/// the band's background. See `TmuxService.processCapturePaneForStreaming`.
///
/// ## Reproduction
///
/// 1. Draw a 6-row full-width gray band (bg setter on the first row, the rest
///    carrying the bg via tmux's cross-line SGR state) with text on alternating
///    rows — mimicking a composer's suggestion list.
/// 2. Park the cursor below it with a foreground process (`cat >/dev/null`) so
///    the shell doesn't print a fresh prompt and nothing redraws the band.
/// 3. Screenshot: the band is fully gray (painted by the live stream).
/// 4. Switch away to another pane and back — this disconnects and re-subscribes
///    the pane stream, forcing `processCapturePaneForStreaming` to rebuild the
///    screen from a fresh `capture-pane`.
/// 5. Screenshot: with the fix every band row is still gray; without it the
///    band's continuation rows (everything below the first) render black.
public enum ComposerBandRecaptureScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Composer Band Recapture",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup ─────────────────────────────────────────────────────

        TestStep.log("Creating tmux sessions")
        TestStep.tmuxCreateSession(name: "composerband-test", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "composerband-helper", width: 80, height: 24)

        Shortcut.tmuxClearAndSetPrompt(target: "composerband-test:0")

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_000, height: 600)

        // Select the test pane so the mirror attaches and starts streaming.
        TestStep.macClickButton(titled: "composerband-test")
        TestStep.wait(seconds: 2)

        // ── Phase 1: Draw the multi-row band via the live stream ──────

        TestStep.log("Phase 1: Drawing a multi-row full-width gray band")

        // Draw a 6-row band, rows 5–10 (1-indexed), positioning the cursor per
        // row (as a TUI composer does) so the rows are not auto-wrapped:
        //   \033[H\033[2J            — clear screen, home
        //   \033[5;1H\033[48;5;243m  — row 5, bg gray ON (set ONCE)
        //   \033[N;1H%-80s × 6       — six full-width rows; the bg carries across
        //                             them via tmux's SGR state, so only row 5
        //                             bears the setter. Text on rows 5/7/9,
        //                             bg-only spaces on rows 6/8/10.
        //   \033[0m                  — reset (after the band)
        //   \033[12;1H               — park cursor on an empty row below
        //   && cat >/dev/null        — hold the foreground so no prompt prints
        //                             and nothing redraws the band.
        //
        // After this, every band row is gray in the real pane; capture-pane
        // emits the gray setter only on row 5.
        Shortcut.tmuxRunCommand(
            target: "composerband-test:0",
            command: #"printf '\033[H\033[2J\033[5;1H\033[48;5;243m%-80s\033[6;1H%-80s\033[7;1H%-80s\033[8;1H%-80s\033[9;1H%-80s\033[10;1H%-80s\033[0m\033[12;1H' '  Ask Codex to do something' '' '  open file on my browser' '' '  summarize recent commits' '' && cat >/dev/null"#
        )
        TestStep.wait(seconds: 2)

        // Screenshot: baseline. The band is fully gray across all six rows,
        // painted directly by the live byte stream.
        TestStep.macScreenshot(label: "mac-01-initial-state")

        // ── Phase 2: Force a re-capture to trigger the bug ────────────

        TestStep.log("Phase 2: Force re-capture by switching panes away and back")

        // De-selecting disconnects the pane stream; re-selecting runs
        // `processCapturePaneForStreaming`. Without the fix, the band's
        // continuation rows (6–10) lose their gray background and render black
        // because their bg arrived via cross-line SGR state that the rebuild
        // resets between rows. With the fix, the band is rebuilt fully gray.
        TestStep.macClickButton(titled: "composerband-helper")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "composerband-test")
        TestStep.wait(seconds: 2)

        TestStep.macScreenshot(label: "mac-02-after-recapture")
    }
}
