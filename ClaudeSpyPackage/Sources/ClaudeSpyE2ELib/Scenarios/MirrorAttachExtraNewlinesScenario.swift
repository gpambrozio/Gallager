import Foundation

/// E2E regression test for issue #429: with the conditional-padding fix
/// landed, the rebuilt visible area must NOT show extra blank rows between
/// log entries on mirror attach when the global auto-resize preference is
/// enabled. The screenshot baseline captures the FIXED rendering.
///
/// Recipe — exercises the production resize-during-attach path that
/// originally produced the double-spacing:
///
///   1. Start with a tmux pane that is significantly WIDER than the mirror
///      window can fit (so auto-resize must shrink it during attach).
///   2. Pre-fill scrollback with paired log entries to give Part 1 + Part 2
///      of the rebuild substantial content to render.
///   3. Resize the mirror window to a narrow width.
///   4. Enable the global "auto-resize all terminal panes…" preference.
///   5. Click the pane to attach. The rebuild captures content at the
///      CURRENT pane width; auto-resize then fires (debounced) and shrinks
///      the tmux pane to fit the mirror window, propagating a layout-change
///      event that resizes the SwiftTerm buffer to fewer cols and triggers
///      `reflowNarrower`. Pre-fix, padded rows reflowed into blank
///      continuation rows; post-fix, ordinary content rows aren't padded,
///      so reflow trims trailing NULL cells and no blanks are produced.
///   6. Screenshot the attach state — the baseline captures the fixed,
///      single-spaced rendering. A regression that reintroduces the
///      pad-everything path will diff against this baseline.
///
/// Companion unit tests `issue429NoBlankRowsOnColsMismatch` and
/// `issue429NoBlankRowsAfterReflowNarrower` deterministically cover the
/// pad-to-width vs. cols mismatch and reflow-narrower paths; this scenario
/// exercises the same fix end-to-end through the resize-during-attach race.
public enum MirrorAttachExtraNewlinesScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Mirror Attach Extra Newlines",
        tags: ["rendering", "macos-only"]
    ) {
        TestStep.log("Creating a WIDE tmux pane (200x40) so auto-resize must shrink it on attach")
        TestStep.tmuxCreateSession(name: "newline-bug", width: 200, height: 40)

        // Pre-fill scrollback with ~120 paired log entries to give Part 1
        // and Part 2 of the rebuild substantial content.
        Shortcut.tmuxRunCommand(
            target: "newline-bug:0",
            command: "for i in $(seq 1 60); do printf '[entry %03d] Checking for work...\\n' $i; printf '[entry %03d] Nothing to do\\n' $i; done"
        )
        TestStep.wait(seconds: 2)

        Shortcut.macOnlySetup
        // Narrow tall window — much smaller than the 200-col pane, so
        // auto-resize will shrink the tmux pane to match.
        TestStep.macResizeWindow(width: 700, height: 1_000)
        TestStep.wait(seconds: 1)

        // Enable global auto-resize.
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macClickButton(titled: "Automatically resize all terminal panes to fit the mirror view when the window size changes")
        TestStep.wait(seconds: 1)
        TestStep.macCloseWindow(titled: "General")
        TestStep.wait(seconds: 1)

        // Click the pane to start the attach. Auto-resize fires shortly
        // after the click, shrinking the tmux pane and triggering the
        // reflow path that exposed #429's double-spacing pre-fix.
        TestStep.macClickButton(titled: "newline-bug")
        TestStep.wait(seconds: 1)

        // Screenshot the post-attach state — the baseline captures the
        // fixed, single-spaced rendering. A regression that reintroduces
        // pad-every-row will diff against this baseline.
        TestStep.macScreenshot(label: "mac-attach-during-resize")
    }
}
