import Foundation

/// E2E scenario: Visual reproduction of terminal rendering bugs
///
/// Demonstrates two bugs in the mirror pipeline:
///
/// **Phase 1 — H17 (SGR state divergence):** Re-capture via
/// `capturePaneWithScrollbackForStreaming` adds `ESC[0m` resets to each line,
/// killing any active SGR state. New text arriving via live stream inherits
/// the reset instead of the original color.
///
/// **Phase 2 — Scrollback corruption:** After building up scrollback via the
/// live PTY stream, re-capture replaces the mirror's content with tmux's
/// captured scrollback. The re-rendered scrollback differs from the live
/// stream's version: content may be duplicated, truncated, or reordered.
///
/// A helper tmux session is used throughout to de-select and re-select the
/// main pane, forcing re-capture.
///
/// All screenshots use `compare: false` — this scenario captures current
/// (buggy) behavior so fixes can be verified later.
///
/// **Note:** H2/H9 (non-CSI/OSC escape leaking) and H3/H8 (cursor position
/// clamping) are confirmed by unit tests but cannot be reproduced via E2E.
/// H2/H9: `capture-pane -e` only outputs SGR codes, never the raw sequences.
/// H3/H8: scrollback absorption during sequential line output compensates
/// for cursor clamping, making before/after renders identical.
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

        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow()
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
        TestStep.macScreenshot(label: "h17-before-recapture-magenta-active")

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
        TestStep.macScreenshot(label: "h17-after-recapture-sgr-divergence")

        // ── Phase 2: Scrollback corruption after re-capture ────────────

        TestStep.log("Phase 2: Scrollback corruption after re-capture")

        // Build up scrollback content via live PTY stream (no re-selecting).
        // Multiple commands in sequence create a distinctive scrollback pattern
        // that should be preserved after re-capture but isn't.
        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: #"printf '\e[0m'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.3)
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "clear", literal: true)
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.5)

        // Fill with numbered lines to create scrollback
        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: #"for i in $(seq 1 35); do echo "LINE $i"; done"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // Clear and add a second batch of output — this pushes the first batch
        // into scrollback, creating a pattern the mirror accumulated via live stream.
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "clear", literal: true)
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.3)
        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: #"echo 'SCROLLBACK TEST: VISIBLE AFTER SCROLL UP'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // Scroll up to reveal the scrollback content accumulated via live stream
        TestStep.macScrollUp(pages: 3)
        TestStep.wait(seconds: 0.5)

        // Screenshot: scrollback as accumulated by live PTY stream
        TestStep.macScreenshot(label: "scrollback-before-recapture")

        // De-select / re-select to force re-capture, which replaces the mirror's
        // scrollback with tmux's captured content — this corrupts the scrollback.
        TestStep.macClickButton(titled: "render-helper:0.0")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "render-bugs:0.0")
        TestStep.wait(seconds: 2)

        // Scroll up again to reveal the re-captured scrollback
        TestStep.macScrollUp(pages: 3)
        TestStep.wait(seconds: 0.5)

        // Screenshot: scrollback after re-capture — compare with previous screenshot
        // to see content duplication, truncation, or reordering.
        TestStep.macScreenshot(label: "scrollback-after-recapture")
    }
}
