import Foundation

/// E2E scenario: Background SGR attribute leak across line boundaries (#411)
///
/// Reproduces the bug reported in issue #411 where Claude Code mirror views
/// sometimes show colored backgrounds on lines that should be plain (e.g., a
/// blue band beneath the prompt or under typed text), while iterm renders the
/// same pane correctly.
///
/// ## The bug
///
/// `processCapturePaneForStreaming` rebuilds the visible area by emitting
/// `\e[2K` (Erase in Line) before each captured row and `\e[J` (Erase in
/// Display) after the last row. EL/ED are *Background Color Erase* (BCE)
/// operations: they paint cleared cells with the *current* SGR background.
///
/// 1. A row is filled edge-to-edge with bg-colored spaces (e.g., a status
///    bar drawn as `\e[44m` followed by spaces to the right margin).
/// 2. `tmux capture-pane -p -e` trims the trailing bg-colored spaces, but
///    keeps the leading `\e[44m` setter on that row.
/// 3. The processor writes that row, then emits `\e[2K` for the next row
///    *without resetting SGR first*. EL clears the next row using bg blue,
///    so every cell on that row is now blue.
/// 4. The next captured line ("> Input prompt") writes a few characters
///    with default attributes, but the cells past those characters keep
///    the leaked blue background.
///
/// Subsequent live-stream bytes inherit whatever the row state is when
/// they land, so typed text appears with a blue band stretching to the
/// right margin — matching the user-reported symptoms.
///
/// ## Reproduction
///
/// 1. Draw a 80-column row of bg-blue spaces at row 5 (`\e[44m` + spaces +
///    `\e[0m`).
/// 2. Park the cursor on row 7 col 0 with a foreground process holding so
///    the shell doesn't print a fresh prompt.
/// 3. Force a re-capture (switch away and back) to invoke
///    `processCapturePaneForStreaming` on this state.
/// 4. Type many lines via `send-keys`. The terminal driver echoes each
///    keystroke through pipe-pane into the mirror's SwiftTerm. If the fix
///    holds, every cell is plain. If the bug regresses, a blue background
///    band fills rows after the prompt — impossible to miss.
public enum BackgroundLeakScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Background SGR Leak",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup ─────────────────────────────────────────────────────

        TestStep.log("Creating tmux sessions")
        TestStep.tmuxCreateSession(name: "bgleak-test", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "bgleak-helper", width: 80, height: 24)

        Shortcut.tmuxClearAndSetPrompt(target: "bgleak-test:0")

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_000, height: 600)

        // Select the test pane so the mirror attaches and starts streaming.
        TestStep.macClickButton(titled: "bgleak-test")
        TestStep.wait(seconds: 2)

        // ── Phase 1: Establish the broken-capture state ──────────────

        TestStep.log("Phase 1: Drawing fully-bg-colored row, parking cursor at col 0 below it")

        // Build the pane state that breaks `processCapturePaneForStreaming`:
        //   \033[H\033[2J   — clear screen, home
        //   \033[5;1H\033[44m — row 5 col 1, bg blue ON
        //   %80s '' — 80 spaces (fills row 5 with bg-blue spaces)
        //   \033[0m — reset (happens after the spaces)
        //   \033[7;1H — cursor to row 7 col 1
        //   && cat >/dev/null — keep foreground process alive so the shell
        //                        doesn't print a new prompt and so typed input
        //                        is drained, letting us send many lines without
        //                        the tty input buffer back-pressuring.
        //
        // After this command, tmux's pane state is:
        //   row 5: 80 bg-blue spaces (capture-pane -p -e keeps the leading
        //          \e[44m but trims the trailing spaces)
        //   rows 6+: empty
        //   cursor at (col 0, row 7 in 1-indexed)
        Shortcut.tmuxRunCommand(
            target: "bgleak-test:0",
            command: #"printf '\033[H\033[2J\033[5;1H\033[44m%80s\033[0m\033[7;1H' '' && cat >/dev/null"#
        )
        TestStep.wait(seconds: 2)

        // Screenshot: baseline. We should see one bg-blue bar on row 5 and
        // empty space everywhere else (no prompt, because cat holds the
        // foreground).
        TestStep.macScreenshot(label: "mac-01-initial-state")

        // ── Phase 2: Force re-capture to trigger the bg-leak bug ──────

        TestStep.log("Phase 2: Force re-capture by switching panes away and back")

        // De-selecting disconnects the pane stream; re-selecting runs
        // `processCapturePaneForStreaming`. Without the fix, the rebuild
        // emits the captured row with `\e[44m`, then `\e[2K` for the next
        // row — which paints the row with bg blue. Every row from there on
        // is bg-blue beyond any rendered character.
        TestStep.macClickButton(titled: "bgleak-helper")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "bgleak-test")
        TestStep.wait(seconds: 2)

        TestStep.macScreenshot(label: "mac-02-after-recapture")

        // ── Phase 3: Type many characters to expose any leaked bg ────

        TestStep.log("Phase 3: Typing many characters via live stream")

        // `cat >/dev/null` is the foreground process, so the terminal driver
        // echoes each keystroke directly through the PTY into pipe-pane and
        // the mirror's SwiftTerm. No shell interaction, no re-render — just
        // pure live-stream byte echo. Each character renders with whatever
        // SGR state SwiftTerm was left in by the re-capture rebuild.
        //
        // If any bg state leaked through the rebuild, every typed line
        // shows a bg-blue band trailing past the text to the right margin.
        // Send in small batches with short waits to avoid back-pressuring
        // the tty's line-discipline buffer.
        for lineNumber in 1...24 {
            TestStep.tmuxSendKeys(
                target: "bgleak-test:0",
                keys: "line \(String(format: "%02d", lineNumber)): no background should appear behind this text\r",
                literal: true
            )
            TestStep.wait(seconds: 0.05)
        }
        // Give pipe-pane time to drain all echoed keystrokes into the
        // mirror's SwiftTerm before the screenshot.
        TestStep.wait(seconds: 2)

        TestStep.macScreenshot(label: "mac-03-typed-lines")
    }
}
