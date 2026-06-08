import Foundation

/// E2E scenario: a multi-row full-width background band loses all but its first
/// row after a re-capture (the Codex composer-band "3rd line doesn't render the
/// background" bug).
///
/// ## The bug
///
/// The Codex composer draws a multi-row full-width background band — rows that
/// set only the bg color, with no printable characters. `tmux capture-pane -p -e`
/// emits the bg setter on the FIRST row of such a run and leaves the rest empty,
/// relying on the terminal carrying the bg across the line breaks:
///
///     row 0: \e[48;2;53;53;53m   (setter, trailing cells trimmed)
///     row 1: (empty)
///     row 2: (empty)
///
/// `processCapturePaneForStreaming` emitted `\e[0m` after every row (added to
/// stop a band leaking into a *different* next row, #411), which killed the
/// carried bg — so each empty continuation row's `\e[K` cleared with the default
/// background and went black. Result: the first band row is gray, the rest are
/// black. The live stream writes real space cells, so the first render is fine;
/// the loss only appears on a **re-capture** (navigating away from the pane and
/// back), which is what this scenario forces.
///
/// ## Reproduction
///
/// 1. A pane draws a 3-row full-width gray band via the live stream → all three
///    rows render gray.
/// 2. Create a second tmux window, switch to its tab and back to force the pane
///    to re-capture through `processCapturePaneForStreaming`.
/// 3. Screenshot. With the carried-background fix all three rows stay gray;
///    without it only the first row is gray and rows 2–3 are black.
public enum BandRecaptureScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Background Band Recapture",
        tags: ["rendering", "macos-only", "tabs"]
    ) {
        // ── Setup ─────────────────────────────────────────────────────
        TestStep.log("Creating a test session for the multi-row background band")
        TestStep.tmuxCreateSession(name: "band-test", width: 120, height: 40)

        Shortcut.tmuxClearAndSetPrompt(target: "band-test:0")

        Shortcut.macOnlySetup
        // Wide enough to show the full 120-col pane and the band rows.
        TestStep.macResizeWindow(width: 1_120, height: 720)

        TestStep.macClickButton(titled: "band-test")
        TestStep.wait(seconds: 2)

        // ── Draw a 3-row full-width gray band via the live stream ──────
        //
        // Rows 6–8 are bg-gray with 120 spaces each (a glyph-free band, like the
        // Codex composer's top padding), followed IMMEDIATELY by a content row
        // (row 9) that resets the background — mirroring the composer's input
        // row. `cat >/dev/null` holds the foreground so no shell prompt redraws.
        // Drawn live, all three band rows render gray. `capture-pane -p -e` later
        // trims the trailing spaces, leaving the setter only on row 6 — the shape
        // that drops rows 7–8 to black on re-capture without the carried-bg fix.
        TestStep.log("Drawing a 3-row full-width bg band + a content row (live stream)")
        Shortcut.tmuxRunCommand(
            target: "band-test:0",
            command: #"printf '\033[H\033[2J\033[6;1H\033[48;2;53;53;53m%120s\033[7;1H%120s\033[8;1H%120s\033[9;1H\033[0m> input row (resets the band)\033[11;1H' '' '' '' && cat >/dev/null"#,
            literal: true
        )
        TestStep.wait(seconds: 2)

        // Pristine: all three band rows render gray.
        TestStep.macScreenshot(label: "mac-01-band-live")

        // ── Force a re-capture via a window-tab away & back ────────────
        // Second window created externally because window 0 is held by cat.
        TestStep.log("Creating a second window, switching tab away and back to force a re-capture")
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "band-test"])
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "band-test:1")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "band-test:0")
        TestStep.wait(seconds: 2)

        // ── Verify: all three rows must still be gray after re-capture ──
        // Before the fix, only the first row keeps its background.
        TestStep.macScreenshot(label: "mac-02-band-after-recapture")
    }
}
