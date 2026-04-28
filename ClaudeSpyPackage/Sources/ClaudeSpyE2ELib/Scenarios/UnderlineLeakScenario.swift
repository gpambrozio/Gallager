import Foundation

/// E2E scenario: Underline SGR attribute leak across line boundaries (#352)
///
/// Reproduces the bug reported in issue #352 where typing in a Claude Code
/// session causes spurious underlines to appear on text that should be plain.
///
/// ## The bug
///
/// `processCapturePaneForStreaming` ends with `extractActiveSGR(...)` being
/// emitted to put SwiftTerm into the same SGR state the real pane has at the
/// cursor. But the information needed to reconstruct that state is missing
/// from tmux's `capture-pane -p` output in one specific case:
///
/// 1. A row is filled edge-to-edge with underlined spaces (an `\e[4m` followed
///    by spaces to the row's right margin — a common pattern for drawing a
///    solid underlined separator).
/// 2. `capture-pane -p` trims the trailing underlined spaces as if they were
///    plain whitespace, keeping only the leading `\e[4m` on that row.
/// 3. If every row below it is empty (no content follows), tmux never emits a
///    corresponding `\e[0m` anywhere in the capture — there is no cell that
///    needs to transition out of underline.
/// 4. `extractActiveSGR` walks the captured lines, sees the `\e[4m`, and —
///    with no reset to match — returns `\e[4m` as the "active" state at the
///    cursor even though the real pane has reset SGR long before the cursor.
///
/// The capture output therefore ends with `\e[4m`, putting SwiftTerm in
/// underline mode. Every subsequent live-stream byte (typed characters,
/// Claude Code's UI redraws, etc.) inherits the underline until some
/// explicit reset reaches SwiftTerm — matching the user-reported symptoms.
///
/// ## Reproduction
///
/// 1. Draw a 80-column row of underlined spaces (with a trailing `\e[0m`)
///    at row 5.
/// 2. Park the cursor on row 7 column 0 and keep the foreground process
///    alive so the shell doesn't print a new prompt.
/// 3. Force a re-capture (switch away and back) to invoke
///    `processCapturePaneForStreaming` on this state.
/// 4. Type many screens' worth of characters via `send-keys`. The terminal
///    driver echoes each keystroke back through the live stream, so every
///    echoed character is rendered with SwiftTerm's post-re-capture SGR
///    state. If the fix holds, every character is plain. If the bug
///    regresses, every character is underlined — hundreds of underlines
///    light up across many rows, impossible to miss.
public enum UnderlineLeakScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Underline SGR Leak",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup ─────────────────────────────────────────────────────

        TestStep.log("Creating tmux sessions")
        TestStep.tmuxCreateSession(name: "uline-test", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "uline-helper", width: 80, height: 24)

        Shortcut.tmuxClearAndSetPrompt(target: "uline-test:0")

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_000, height: 600)

        // Select the test pane so the mirror attaches and starts streaming.
        TestStep.macClickButton(titled: "uline-test")
        TestStep.wait(seconds: 2)

        // ── Phase 1: Establish the broken-capture state ──────────────

        TestStep.log("Phase 1: Drawing fully-underlined row, parking cursor at col 0 below it")

        // Build the pane state that breaks `extractActiveSGR`:
        //   \033[H\033[2J   — clear screen, home
        //   \033[5;1H\033[4m — row 5 col 1, underline ON
        //   %80s '' — 80 spaces (fills row 5 with underlined spaces)
        //   \033[0m — reset (happens after the spaces)
        //   \033[7;1H — cursor to row 7 col 1
        //   && sleep 60 — keep foreground process alive so the shell doesn't
        //                 print a new prompt (which would move cursor away
        //                 from col 0 and mask the bug).
        //
        // After this command, tmux's pane state is:
        //   row 5: 80 underlined spaces (trimmed by capture-pane -p to \e[4m)
        //   rows 6+: empty
        //   cursor at (col 0, row 6 in 0-indexed / row 7 in 1-indexed)
        // `cat >/dev/null` holds the foreground process so the shell doesn't
        // print a new prompt (which would move cursor off col 0 and mask the
        // bug), while still draining the tty input buffer. `sleep` would also
        // hold the foreground, but wouldn't drain — typing would stall after
        // ~1 KB of buffered input. `cat` lets us type many lines in Phase 3.
        Shortcut.tmuxRunCommand(
            target: "uline-test:0",
            command: #"printf '\033[H\033[2J\033[5;1H\033[4m%80s\033[0m\033[7;1H' '' && cat >/dev/null"#
        )
        TestStep.wait(seconds: 2)

        // Screenshot: baseline. We should see one underlined bar on row 5 and
        // empty space everywhere else (no prompt, because sleep holds the
        // foreground).
        TestStep.macScreenshot(label: "mac-01-initial-state")

        // ── Phase 2: Force re-capture to trigger extractActiveSGR bug ─

        TestStep.log("Phase 2: Force re-capture by switching panes away and back")

        // De-selecting disconnects the pane stream; re-selecting runs
        // `processCapturePaneForStreaming`, which invokes `extractActiveSGR`
        // with cursorX=0, cursorY=6. With no \e[0m in the capture (all rows
        // below the underlined one are empty), the function returns \e[4m
        // without the fix, leaving SwiftTerm in underline mode after the
        // capture output.
        TestStep.macClickButton(titled: "uline-helper")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "uline-test")
        TestStep.wait(seconds: 2)

        TestStep.macScreenshot(label: "mac-02-after-recapture")

        // ── Phase 3: Type many characters to expose any leaked underline ─

        TestStep.log("Phase 3: Typing many characters via live stream")

        // `cat >/dev/null` is the foreground process, so the terminal driver
        // echoes each keystroke we send directly back through the PTY, into
        // pipe-pane, into the mirror's SwiftTerm. No shell interaction, no
        // re-render — just pure live-stream byte echo. That means each char
        // renders with whatever SGR state SwiftTerm was left in by the
        // re-capture. `cat` also reads stdin (discarding to /dev/null) so
        // the tty's line-discipline input buffer doesn't back-pressure and
        // drop characters after ~1 KB.
        //
        // If any underline state leaked through the capture, every one of
        // these characters across 14 rows shows a horizontal underscore
        // stroke beneath it.
        // Send in small batches with short waits. A single large literal
        // payload (~1.2 KB) can race with the tty's line-discipline buffer
        // and drop chars mid-stream; chunking keeps each batch small enough
        // to deliver reliably.
        for lineNumber in 1...14 {
            TestStep.tmuxSendKeys(
                target: "uline-test:0",
                keys: "line \(String(format: "%02d", lineNumber)): no underline should appear under this text\r",
                literal: true
            )
            TestStep.wait(seconds: 0.05)
        }
        // Give the pipe-pane live stream time to drain all echoed keystrokes
        // into the mirror's SwiftTerm before the screenshot.
        TestStep.wait(seconds: 2)

        TestStep.macScreenshot(label: "mac-03-typed-lines")
    }
}
