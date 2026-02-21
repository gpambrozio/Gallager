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

        // Put colored content into the main pane BEFORE the app launches.
        // This content will be captured by capturePaneWithScrollbackForStreaming
        // on first connection.
        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: "clear",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.5)

        // Output colored lines: green, red, blue, and magenta (no trailing reset)
        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: #"printf '\e[32mGreen line\e[0m\n\e[31mRed line\e[0m\n\e[34mBlue line\e[0m\n\e[35mMagenta no reset '"#,
            literal: true
        )
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

        // Select the main pane — initial capture has already run
        TestStep.macClickButton(titled: "render-bugs:0.0")
        TestStep.wait(seconds: 2)

        // Screenshot: baseline state from initial capture (live stream was active from launch)
        TestStep.macScreenshot(label: "initial-capture-baseline", compare: false)

        // De-select / re-select to force a re-capture and screenshot the result
        TestStep.macClickButton(titled: "render-helper:0.0")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "render-bugs:0.0")
        TestStep.wait(seconds: 2)

        // Screenshot: after re-capture — compare visually with baseline above.
        // The re-capture reconstructs content via capturePaneWithScrollbackForStreaming
        // which adds ESC[0m resets per line; any SGR state that was carrying over
        // (e.g. the magenta-no-reset line) will be killed.
        TestStep.macScreenshot(label: "after-recapture-baseline", compare: false)

        // ── Phase 1: H3/H8 — Cursor position clamping ───────────────

        TestStep.log("Phase 1: H3/H8 — Cursor position clamping on dimension mismatch")

        // Fill the tmux pane with numbered content so the cursor sits at a high row
        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: #"for i in $(seq 1 35); do echo "FILL LINE $i"; done"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // Resize the macOS window to be smaller — fewer visible rows than tmux's 40
        TestStep.macResizeWindow(width: 800, height: 400)
        TestStep.wait(seconds: 1)

        // De-select / re-select to force re-capture with cursor clamping
        TestStep.macClickButton(titled: "render-helper:0.0")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "render-bugs:0.0")
        TestStep.wait(seconds: 2)

        // Type a printf that uses CursorUp to write a marker at a specific row.
        // Due to clamping, the marker will appear at the wrong position.
        TestStep.macType(
            text: #"printf '\e[5A\r>>> CLAMPED MARKER <<<\e[5B\r'"#,
            pressReturn: true
        )
        TestStep.wait(seconds: 1)

        // Screenshot: marker may appear at wrong row due to cursor clamping
        TestStep.macScreenshot(label: "h3-h8-cursor-clamping", compare: false)

        // ── Phase 2: H17 — SGR state divergence after re-capture ─────

        TestStep.log("Phase 2: H17 — SGR state divergence after re-capture")

        // Resize back to see more content
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        // Output magenta text WITHOUT a trailing reset.
        // In the raw PTY stream, the SGR state (magenta) persists for subsequent output.
        TestStep.macType(
            text: #"printf '\e[35mMAGENTA-NO-RESET '"#,
            pressReturn: true
        )
        TestStep.wait(seconds: 1)

        // Screenshot before re-capture: shell prompt after the text should inherit magenta
        TestStep.macScreenshot(label: "h17-before-recapture", compare: false)

        // De-select / re-select to force re-capture.
        // capturePaneWithScrollbackForStreaming adds ESC[0m resets at end of each line,
        // killing the magenta state. After re-capture, the prompt that was magenta
        // will render in the default color.
        TestStep.macClickButton(titled: "render-helper:0.0")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "render-bugs:0.0")
        TestStep.wait(seconds: 2)

        // Screenshot after re-capture: the prompt text that was magenta should now
        // be default color — demonstrating the SGR state divergence.
        TestStep.macScreenshot(label: "h17-after-recapture-sgr-divergence", compare: false)
    }
}
