import Foundation

/// E2E scenario: a multi-row background band that has scrolled into *history*
/// loses its background on re-capture (#580 — the scrollback analogue of #578).
///
/// ## The bug
///
/// PR #579 fixed multi-row background bands in the **visible** area by capturing
/// it with `tmux capture-pane -e -N` (preserve trailing spaces) and carrying the
/// cross-line SGR state when rebuilding the rows. The **scrollback** capture was
/// intentionally left on plain `-e` and still reset the SGR state per line, so a
/// band that scrolled into history had the exact same root cause: tmux trims the
/// band's continuation-row spaces (they bear no setter of their own — the bg is
/// carried via tmux's cross-line SGR state) and the rebuild reset the state
/// between rows, so those rows rendered with the default (black) background.
///
/// ## The fix
///
/// Apply `-N` to the scrollback capture too and carry the SGR state across
/// scrollback rows, exactly as the visible area does. To keep static history
/// reflow-safe, `processCapturePaneForStreaming` trims the now-preserved
/// *default*-bg trailing spaces back off plain rows (a band's non-default-bg
/// spaces are kept). See `TmuxService.processCapturePaneForStreaming` and
/// `trimTrailingDefaultBackgroundSpaces`.
///
/// ## Reproduction
///
/// 1. Draw a 6-row full-width gray band (bg setter on the first row, the rest
///    carrying the bg via tmux's cross-line SGR state) as normal output lines.
///    Screenshot — the band is fully gray in the visible area (painted by the
///    live byte stream).
/// 2. Print a screenful-plus of filler so the band scrolls up into history
///    (above the visible fold). Park the cursor with a foreground process
///    (`cat >/dev/null`) so nothing redraws.
/// 3. Switch away to another pane and back — this disconnects and re-subscribes
///    the pane stream, forcing `processCapturePaneForStreaming` to rebuild the
///    scrollback from a fresh `capture-pane`.
/// 4. Scroll up to reveal the band in the rebuilt history and screenshot — with
///    the fix every band row is still gray; without it the band's continuation
///    rows render black.
public enum ScrollbackBandRecaptureScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Scrollback Band Recapture",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup ─────────────────────────────────────────────────────

        TestStep.log("Creating tmux sessions")
        TestStep.tmuxCreateSession(name: "scrollbackband-test", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "scrollbackband-helper", width: 80, height: 24)

        Shortcut.tmuxClearAndSetPrompt(target: "scrollbackband-test:0")

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_000, height: 600)

        // Select the test pane so the mirror attaches and starts streaming.
        TestStep.macClickButton(titled: "scrollbackband-test")
        TestStep.wait(seconds: 2)

        // ── Phase 1: Draw the band (still on screen) ──────────────────

        TestStep.log("Phase 1: Drawing a multi-row gray band")

        // Draw a 6-row band as normal output lines (so it can later scroll):
        //   \033[48;5;243m   — bg gray ON (set ONCE, before the first row)
        //   %-80s\n × 6      — six full-width rows; the bg carries across them
        //                      via tmux's SGR state, so only the first bears the
        //                      setter. Text on rows 1/3/5, bg-only spaces on 2/4/6.
        //   \033[0m          — reset (after the band)
        // The shell prints a fresh prompt below it, leaving the band gray in the
        // visible area.
        Shortcut.tmuxRunCommand(
            target: "scrollbackband-test:0",
            command: #"printf '\033[48;5;243m%-80s\n%-80s\n%-80s\n%-80s\n%-80s\n%-80s\033[0m\n' '  Ask Codex to do something' '' '  open file on my browser' '' '  summarize recent commits' ''"#
        )
        TestStep.wait(seconds: 2)

        // Screenshot: the band is fully gray across all six rows in the visible
        // area, painted directly by the live byte stream.
        TestStep.macScreenshot(label: "mac-01-band-visible")

        // ── Phase 2: Scroll the band into history, then re-capture ────

        TestStep.log("Phase 2: Scroll the band into history and force a re-capture")

        // Print a screenful-plus of filler so the band scrolls above the visible
        // fold (24 rows) into scrollback history; `cat >/dev/null` then holds the
        // foreground so no prompt prints and nothing redraws.
        Shortcut.tmuxRunCommand(
            target: "scrollbackband-test:0",
            command: #"for i in $(seq 1 30); do echo "scrollback filler line $i"; done && cat >/dev/null"#
        )
        TestStep.wait(seconds: 2)

        // De-selecting disconnects the pane stream; re-selecting runs
        // `processCapturePaneForStreaming`, which rebuilds the scrollback from a
        // fresh `capture-pane`. Without the fix, the band's continuation rows
        // lose their gray background in history and render black. With the fix
        // (`-N` on the scrollback capture + cross-line SGR carry), the band is
        // rebuilt fully gray.
        TestStep.macClickButton(titled: "scrollbackband-helper")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "scrollbackband-test")
        TestStep.wait(seconds: 2)

        // Re-selecting resets the scroll position to the bottom — scroll up to
        // reveal the (now re-captured) band sitting in history. With the fix it
        // is still fully gray across all six rows.
        TestStep.macScrollUp(pages: 6)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-02-after-recapture")
    }
}
