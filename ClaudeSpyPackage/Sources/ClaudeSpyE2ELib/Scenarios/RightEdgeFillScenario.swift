import Foundation

/// E2E scenario: full-pane-width background bands reach the right edge.
///
/// Reproduces the Codex rendering bug where filled prompt/message panels —
/// drawn as a background color spanning the whole pane width — appeared
/// truncated in the mirror: the cells were filled, but the strip between the
/// last cell and the view's right edge (SwiftTerm reserves ~1 column for its
/// unused internal legacy scroller, plus the horizontal sizing buffer) showed
/// the default terminal background. iTerm renders the same pane edge-to-edge.
///
/// `InteractiveTerminalView.updateRightEdgeBackground()` fixes this by extending
/// each row's trailing-cell background into that reserved margin.
///
/// ## Reproduction
///
/// A pane displayed in a window wider than the pane's cell content leaves a
/// reserved-scroller margin on the right. Painting the top rows full-width with
/// a background color (`\e[44m\e[K` — set bg, erase-to-end-of-line is BCE, so it
/// fills the row with the active bg) makes the margin obvious: without the fix a
/// dark strip cuts the band short of the edge; with the fix the band reaches the
/// edge.
public enum RightEdgeFillScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Right Edge Background Fill",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup ─────────────────────────────────────────────────────

        TestStep.log("Creating tmux sessions")
        TestStep.tmuxCreateSession(name: "rightedge-test", width: 120, height: 40)
        // Helper session to switch to, forcing a re-capture rebuild on return.
        TestStep.tmuxCreateSession(name: "rightedge-helper", width: 120, height: 40)

        Shortcut.tmuxClearAndSetPrompt(target: "rightedge-test:0")

        Shortcut.macOnlySetup
        // A window wider than the pane content guarantees a reserved-scroller
        // margin on the right edge.
        TestStep.macResizeWindow(width: 1_600, height: 800)

        // Select the test pane so the mirror attaches and starts streaming.
        TestStep.macClickButton(titled: "rightedge-test")
        TestStep.wait(seconds: 2)

        // ── Draw full-pane-width background bands ─────────────────────

        TestStep.log("Drawing full-width background bands via BCE")

        // Clear, then paint the top rows like Codex's filled panels: a non-bg
        // leading marker ("> "), then a bg-blue band carrying text, then `\e[K`
        // (BCE) which extends the blue past the text to the pane's last cell.
        // The default-bg leading marker is deliberate — it matches Codex's `›`
        // gutter and forces `capture-pane` to re-state the bg on every row
        // (instead of relying on cross-line SGR carryover, which the capture
        // rebuild resets per line). That's what lets the panels survive the
        // re-capture rebuild below with their background intact. `cat >/dev/null`
        // holds the foreground so no prompt redraws over the panels.
        Shortcut.tmuxRunCommand(
            target: "rightedge-test:0",
            command: #"printf '\033[H\033[2J'; for r in $(seq 1 20); do printf '\033[0m> \033[44m panel row %02d \033[K\033[0m\r\n' "$r"; done; cat >/dev/null"#
        )
        TestStep.wait(seconds: 2)

        // Screenshot: every painted row's blue background must reach the view's
        // right edge — no dark strip between the band and the window border.
        // (Live-stream render path.)
        TestStep.macScreenshot(label: "mac-01-full-width-bands")

        // ── Force a re-capture and re-verify ──────────────────────────

        // Switching away and back rebuilds the visible area through
        // `processCapturePaneForStreaming` (capture-pane trims the trailing
        // bg-colored cells, then `\e[K` BCE refills them). The right-edge fill
        // reads the rebuilt cells, so the bands must still reach the edge.
        TestStep.log("Switching away and back to force a re-capture rebuild")
        TestStep.macClickButton(titled: "rightedge-helper")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "rightedge-test")
        TestStep.wait(seconds: 2)

        TestStep.macScreenshot(label: "mac-02-after-recapture")
    }
}
