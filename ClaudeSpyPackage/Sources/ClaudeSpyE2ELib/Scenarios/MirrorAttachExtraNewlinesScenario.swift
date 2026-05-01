import Foundation

/// E2E reproducer for issue #429: extra blank rows between log entries on
/// mirror attach when the global auto-resize preference is enabled.
///
/// Reproduction recipe (verified to deterministically show double-spacing
/// in the rebuilt visible area on the FIRST attach screenshot):
///
///   1. Start with a tmux pane that is significantly WIDER than the mirror
///      window can fit (so auto-resize must shrink it during attach).
///   2. Pre-fill scrollback with paired log entries to give Part 1 + Part 2
///      of the rebuild substantial content to render.
///   3. Resize the mirror window to a narrow width.
///   4. Enable the global "auto-resize all terminal panes…" preference.
///   5. Click the pane to attach. The rebuild captures and pads content to
///      the CURRENT pane width; the visible content fills `width`-wide
///      lines. Auto-resize then fires (debounced) and shrinks the tmux
///      pane to fit the mirror window, propagating a layout-change event
///      that resizes the SwiftTerm buffer to fewer cols. SwiftTerm's
///      `reflowNarrower` re-flows the buffer rows; padded lines whose
///      trimmed length already equals the new cols can re-emerge with
///      blank continuation rows interleaved between them — exactly the
///      double-spacing the user reports.
///   6. Screenshot the attach state (`compare: false`) so the screenshot
///      captures the transient double-spaced rendering. Visual inspection
///      of the screenshot is what confirms reproduction.
///
/// Note: this scenario reproduces the VISUAL bug on the buggy code path.
/// The companion unit test `issue429NoBlankRowsOnColsMismatch` covers the
/// underlying pad-to-width vs. mirror cols mismatch deterministically.
/// The auto-resize-induced reflow path is timing-sensitive and not always
/// caught by the unit test, so this scenario complements it by exercising
/// the production resize-during-attach race directly.
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
        // reflow path that exposes #429's double-spacing.
        TestStep.macClickButton(titled: "newline-bug")
        TestStep.wait(seconds: 1)

        // Screenshot the transient state — the rebuilt visible area
        // should show double-spaced log entries on the buggy code path.
        TestStep.macScreenshot(label: "mac-attach-during-resize")
    }
}
