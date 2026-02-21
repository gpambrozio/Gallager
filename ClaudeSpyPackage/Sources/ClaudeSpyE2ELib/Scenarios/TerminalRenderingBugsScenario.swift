import Foundation

/// E2E scenario: Visual reproduction of terminal rendering bugs
///
/// Documents known garbling from `filterToColorCodesOnly` (H2/H9),
/// cursor position clamping (H3/H8), and SGR state divergence (H17).
///
/// All screenshots use `compare: false` — this scenario captures current
/// (buggy) behavior so fixes can be verified later.
///
/// **Important:** H2/H9 bugs only manifest during the initial capture
/// (`capturePaneWithScrollbackForStreaming`), which runs when the macOS app
/// first connects to a pane. Content must be present in tmux BEFORE the app
/// launches, hence the use of `tmuxSendKeys` instead of `macType`.
public enum TerminalRenderingBugsScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal Rendering Bugs",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Phase 1: H2/H9 — Non-CSI and OSC escape leaking ──────────

        TestStep.log("Phase 1: H2/H9 — Non-CSI and OSC escape leaking during initial capture")

        // Create a tmux session and populate it BEFORE the app connects.
        // filterToColorCodesOnly runs on initial capture and leaks bytes
        // from non-CSI escapes (ESC(B → literal "(B") and OSC sequences
        // (ESC]0;Title BEL → literal "]0;Title").
        TestStep.tmuxCreateSession(name: "render-bugs", width: 120, height: 40)

        // Clear and output test content with various escape types.
        // The printf uses $'...' syntax to embed raw escape codes.
        //
        // Line 1: SGR color (green) + ESC(B (charset reset) + normal text + SGR (red)
        //   Correct rendering: "LINE-A: Green Normal Red" (charset escapes invisible)
        //   Buggy rendering:   "LINE-A: Green(B Normal Red" ((B leaks as literal text)
        //
        // Line 2: ESC)0 (VT100 line drawing charset) + text
        //   Correct: "LINE-B: After charset switch"
        //   Buggy:   "LINE-B: )0After charset switch" ()0 leaks)
        //
        // Line 3: OSC title sequence + text
        //   Correct: "LINE-C: After title set"
        //   Buggy:   "LINE-C: ]0;TestTitle" + BEL char + "After title set" (OSC leaks)
        //
        // Line 4: Plain SGR only (should render correctly as a control comparison)
        //   Both:   "LINE-D: Blue text Normal text"
        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: "clear",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.5)

        // Use printf to emit escape sequences that trigger the bugs.
        // Each line is a separate printf to keep things readable.
        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: #"printf '\e[32mGreen\e(BNormal \e[31mRed\e[0m' && echo ' ← LINE-A (H2: charset leak)'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.3)

        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: #"printf '\e)0After charset switch' && echo ' ← LINE-B (H2: VT100 leak)'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.3)

        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: #"printf '\e]0;TestTitle\aAfter title set' && echo ' ← LINE-C (H9: OSC leak)'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.3)

        TestStep.tmuxSendKeys(
            target: "render-bugs:0.0",
            keys: #"printf '\e[34mBlue text \e[0mNormal text' && echo ' ← LINE-D (control: SGR only)'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "render-bugs:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.5)

        // Now launch the app — it will connect, run capturePaneWithScrollbackForStreaming,
        // and filterToColorCodesOnly will garble lines A, B, and C.
        TestStep.launchMacApp
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(200)
        TestStep.wait(seconds: 1)

        // Select the pane to view mirrored content
        TestStep.macClickButton(titled: "render-bugs:0.0")
        TestStep.wait(seconds: 2)

        // Screenshot: Should show garbled text on lines A/B/C, correct text on line D
        TestStep.macScreenshot(label: "h2-h9-initial-capture-garbling", compare: false)

        // ── Phase 2: H3/H8 — Cursor position clamping ───────────────

        TestStep.log("Phase 2: H3/H8 — Cursor position clamping on dimension mismatch")

        // Fill the tmux pane with numbered content so we have many rows
        // (cursor will be at a high row number)
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

        // Create a second pane to force a re-capture when we switch back
        TestStep.tmuxCreateSession(name: "render-bugs-2", width: 120, height: 40)
        TestStep.wait(seconds: 1)

        // Switch to the second pane
        TestStep.macClickButton(titled: "render-bugs-2:0.0")
        TestStep.wait(seconds: 1)

        // Switch back — triggers capturePaneWithScrollbackForStreaming with cursor clamping
        TestStep.macClickButton(titled: "render-bugs:0.0")
        TestStep.wait(seconds: 2)

        // Now type a command that uses CursorUp to write a MARKER at a specific row.
        // Due to clamping, the marker will appear at the wrong position.
        TestStep.macType(
            text: #"printf '\e[5A\r>>> CLAMPED MARKER <<<\e[5B\r'"#,
            pressReturn: true
        )
        TestStep.wait(seconds: 1)

        // Screenshot: MARKER may appear at wrong row due to cursor clamping
        TestStep.macScreenshot(label: "h3-h8-cursor-clamping", compare: false)

        // ── Phase 3: H17 — SGR state divergence after re-capture ─────

        TestStep.log("Phase 3: H17 — SGR state divergence after re-capture")

        // Resize back to see more content
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        // Output magenta text WITHOUT a trailing reset.
        // In a raw terminal, the SGR state (magenta) persists for subsequent output.
        TestStep.macType(
            text: #"printf '\e[35mMAGENTA-NO-RESET '"#,
            pressReturn: true
        )
        TestStep.wait(seconds: 1)

        // Screenshot before re-capture: shell prompt after the text should inherit magenta
        TestStep.macScreenshot(label: "h17-before-recapture", compare: false)

        // Switch to second pane and back to force a re-capture.
        // capturePaneWithScrollbackForStreaming adds ESC[0m resets at end of each line,
        // killing the magenta state. After re-capture, new output (like the shell prompt)
        // will render in default color instead of magenta.
        TestStep.macClickButton(titled: "render-bugs-2:0.0")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "render-bugs:0.0")
        TestStep.wait(seconds: 2)

        // Screenshot after re-capture: the prompt text that was magenta may now be default color
        TestStep.macScreenshot(label: "h17-after-recapture-sgr-divergence", compare: false)
    }
}
