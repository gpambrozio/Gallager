import Foundation

/// E2E scenario: Truecolor gradient rendering stress test
///
/// Regression test for the pipe-pane streaming rewrite (PR #179).
/// Runs 5 variants of a truecolor gradient animation, each with different
/// box dimensions, color palettes, and layout densities:
///
///   1. **Standard** — 6 boxes (50x5), baseline gradients
///   2. **Wide Warm** — 4 large boxes (55x7), warm-shifted palette
///   3. **Small Cool** — 9 small boxes (25x3, 3x3 grid), cool-shifted
///   4. **Full-Width Bars** — 6 bars (100x3), maximum horizontal span
///   5. **Dense Rainbow** — 12 tiny boxes (20x4, 4x3 grid), rapid animation
///
/// Each variant animates 40 frames using mode 2026 synchronized output,
/// then draws a final static frame. Screenshots are taken on both macOS
/// and iOS mirrors after each run to verify artifact-free rendering on
/// both platforms.
///
/// The Python script is created as a temp file via heredoc, run 5 times
/// with different `V=` env vars, then cleaned up — fully self-contained.
///
/// Screenshots are compared against baselines with default tolerance.
public enum TruecolorRenderingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Truecolor Rendering Stress",
        tags: ["rendering"]
    ) {
        // ── Pair devices ────────────────────────────────────────────
        // Pairing launches both apps and establishes the relay connection.
        // Do this before creating tmux sessions so the session survives
        // app restarts during the pairing flow.

        FreshPairingScenario.scenario

        // ── Setup ─────────────────────────────────────────────────────

        TestStep.log("Creating tmux session for truecolor stress test")
        TestStep.tmuxCreateSession(name: "truecolor-test", width: 120, height: 40)
        TestStep.wait(seconds: 3)

        Shortcut.openPanesWindow()
        TestStep.macResizeWindow(width: 1_200, height: 700)

        TestStep.macClickButton(titled: "truecolor-test")
        TestStep.wait(seconds: 2)

        // ── Navigate to pane on iOS ─────────────────────────────────

        TestStep.log("Opening terminal pane on iOS mirror")
        Shortcut.iosConnectToSession(sessionName: "truecolor-test")

        // ── Inject the parameterized Python script ─────────────���──────
        //
        // V=0..4 selects variant. Each variant has different:
        //   - Box dimensions (width x height)
        //   - Grid layout (columns x rows)
        //   - Animation speed (ms per frame)
        //   - Color palette shift (degrees)

        TestStep.log("Injecting parameterized truecolor script")
        TestStep.injectScript(name: "truecolor.py")

        // ── Variant 1: Standard gradients (6 boxes, 50x5) ───────────

        TestStep.log("Variant 1/5: Standard Gradients")
        Shortcut.tmuxRunCommand(target: "truecolor-test:0", command: "V=0 python3 $TMPDIR/truecolor.py")
        TestStep.wait(seconds: 6)
        TestStep.macScreenshot(label: "mac-v1-standard-gradients")
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-v1-standard-gradients")

        // ── Variant 2: Wide warm boxes (4 boxes, 55x7) ──────────────

        TestStep.log("Variant 2/5: Wide Warm Boxes")
        Shortcut.tmuxRunCommand(target: "truecolor-test:0", command: "V=1 python3 $TMPDIR/truecolor.py")
        TestStep.wait(seconds: 6)
        TestStep.macScreenshot(label: "mac-v2-wide-warm-boxes")
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-v2-wide-warm-boxes")

        // ── Variant 3: Small cool grid (9 boxes, 25x3) ──────────────

        TestStep.log("Variant 3/5: Small Cool Grid")
        Shortcut.tmuxRunCommand(target: "truecolor-test:0", command: "V=2 python3 $TMPDIR/truecolor.py")
        TestStep.wait(seconds: 6)
        TestStep.macScreenshot(label: "mac-v3-small-cool-grid")
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-v3-small-cool-grid")

        // ── Variant 4: Full-width bars (6 bars, 100x3) ──────────────

        TestStep.log("Variant 4/5: Full-Width Bars")
        Shortcut.tmuxRunCommand(target: "truecolor-test:0", command: "V=3 python3 $TMPDIR/truecolor.py")
        TestStep.wait(seconds: 6)
        TestStep.macScreenshot(label: "mac-v4-full-width-bars")
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-v4-full-width-bars")

        // ── Variant 5: Dense rainbow grid (12 boxes, 20x4) ──────────

        TestStep.log("Variant 5/5: Dense Rainbow Grid")
        Shortcut.tmuxRunCommand(target: "truecolor-test:0", command: "V=4 python3 $TMPDIR/truecolor.py")
        TestStep.wait(seconds: 6)
        TestStep.macScreenshot(label: "mac-v5-dense-rainbow-grid")
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-v5-dense-rainbow-grid")
    }
}
