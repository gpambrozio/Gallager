import Foundation

/// E2E scenario: Visual reproduction of terminal rendering bugs
///
/// Documents cursor position clamping (H3/H8) and SGR state divergence (H17)
/// in the mirror pipeline. A helper tmux session is used throughout to
/// de-select and re-select the main pane, forcing re-capture via
/// `capturePaneWithScrollbackForStreaming`.
///
/// All screenshots use `compare: false` — this scenario captures current
/// (buggy) behavior so fixes can be verified later.
///
/// **Note:** H2/H9 (non-CSI/OSC escape leaking in `filterToColorCodesOnly`)
/// are confirmed by unit tests but cannot be reproduced via E2E because
/// `capture-pane -e` only outputs SGR codes, never the raw sequences that
/// trigger those bugs.
public enum TerminalRenderingBugsScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal Rendering Bugs",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup ─────────────────────────────────────────────────────

        TestStep.log("Creating tmux sessions")
        TestStep.tmuxCreateSession(name: "render-bugs", width: 120, height: 40)
        TestStep.tmuxCreateSession(name: "render-helper", width: 120, height: 40)

        // Set a plain prompt with no color codes so SGR inheritance is clearly visible.
        // Without this, the shell's default PS1 (with its own colors) would mask
        // the magenta carryover in the H17 phase.
        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: #"export PS1='$ '"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "clear", literal: true)
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.5)

        TestStep.launchMacApp
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(200)
        TestStep.wait(seconds: 1)

        // Select the main pane
        TestStep.macClickButton(titled: "render-bugs:0.0")
        TestStep.wait(seconds: 2)

        // ── Phase 1: H17 — SGR state divergence after re-capture ─────

        TestStep.log("Phase 1: H17 — SGR state divergence after re-capture")

        // Set magenta with no reset, then echo text that inherits the color.
        // In the live PTY stream, everything after \e[35m inherits magenta
        // until an explicit reset.
        TestStep.macType(
            text: #"printf '\e[35m' && echo 'BEFORE_RECAP: SHOULD BE MAGENTA'"#,
            pressReturn: true
        )
        TestStep.wait(seconds: 1)

        // Screenshot: "BEFORE_RECAP: SHOULD BE MAGENTA" and the "$ " prompt
        // below it should both appear in magenta (SGR state carries over).
        TestStep.macScreenshot(label: "h17-before-recapture-magenta-active", compare: false)

        // De-select / re-select to force re-capture.
        // capturePaneWithScrollbackForStreaming adds ESC[0m resets at end of each
        // captured line, killing the active magenta SGR state. After re-capture,
        // the terminal's SGR state is reset to default.
        TestStep.macClickButton(titled: "render-helper:0.0")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "render-bugs:0.0")
        TestStep.wait(seconds: 2)

        // Now echo more text — this arrives via live stream with no color codes,
        // so it inherits whatever SGR state the terminal has. If the re-capture
        // reset it (the bug), this text appears in default color instead of magenta.
        TestStep.macType(
            text: "echo 'AFTER_RECAP: SHOULD ALSO BE MAGENTA (but is default color)'",
            pressReturn: true
        )
        TestStep.wait(seconds: 1)

        // Screenshot: compare with the previous one.
        // "BEFORE_RECAP" text is still magenta (already rendered).
        // "AFTER_RECAP" text is DEFAULT color — proving the re-capture killed
        // the active SGR state. This is the H17 bug.
        TestStep.macScreenshot(label: "h17-after-recapture-sgr-divergence", compare: false)

        // ── Phase 2: H3/H8 — Cursor position clamping ───────────────

        TestStep.log("Phase 2: H3/H8 — Cursor position clamping on dimension mismatch")

        // Reset colors and fill via tmuxSendKeys (bypasses app input path to
        // avoid AppleScript timing issues with multi-line shell commands).
        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: #"printf '\e[0m' && for i in $(seq 1 35); do echo "FILL LINE $i"; done"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 2)

        // Resize the macOS window to be smaller — fewer visible rows than tmux's 40
        TestStep.macResizeWindow(width: 800, height: 400)
        TestStep.wait(seconds: 1)

        // De-select / re-select to force re-capture with cursor clamping.
        // The tmux cursor is at a high row (e.g. 38), but the mirror has fewer
        // rows, so the cursor position gets clamped to the mirror's max row.
        TestStep.macClickButton(titled: "render-helper:0.0")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "render-bugs:0.0")
        TestStep.wait(seconds: 2)

        // Use tmuxSendKeys for the marker printf — the escape codes in the output
        // arrive via the live PTY stream and are interpreted by SwiftTerm.
        // CursorUp:5 should go 5 rows above the cursor, but since the cursor was
        // clamped during re-capture, it lands at the wrong row.
        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: #"printf '\e[5A\r>>> CLAMPED MARKER <<<\e[5B\r'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // Screenshot: marker may appear at wrong row due to cursor clamping
        TestStep.macScreenshot(label: "h3-h8-cursor-clamping", compare: false)

        // De-select / re-select to see how the clamped marker looks after re-render
        TestStep.macClickButton(titled: "render-helper:0.0")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "render-bugs:0.0")
        TestStep.wait(seconds: 2)

        TestStep.macScreenshot(label: "h3-h8-cursor-clamping-after-rerender", compare: false)
    }
}
