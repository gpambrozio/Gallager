import Foundation

/// E2E regression for issue #429: extra blank rows between log entries on
/// the FIRST mirror attach to a tmux pane that already has scrollback of
/// paired log lines (cibot's `Checking for work…` / `Nothing to do`
/// cadence).
///
/// Strategy: pre-fill the pane's scrollback with paired entries so the
/// rebuild's Part 1 (scrollback) and Part 2 (visible) paths both exercise
/// the cadence. Attach the mirror, screenshot the initial view, then scroll
/// up and screenshot the scrollback. Both screenshots are compared against
/// baselines — any future regression that re-introduces the wrap-induced
/// blank rows would change the baseline.
public enum MirrorAttachExtraNewlinesScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Mirror Attach Extra Newlines",
        tags: ["rendering", "macos-only"]
    ) {
        TestStep.log("Creating tmux session for paired-log rendering")
        TestStep.tmuxCreateSession(name: "newline-bug", width: 80, height: 40)

        // Pre-fill scrollback with ~120 paired log entries so Part 1 of the
        // rebuild has substantial content to render alongside Part 2.
        Shortcut.tmuxRunCommand(
            target: "newline-bug:0",
            command: "for i in $(seq 1 60); do printf '[entry %03d] Checking for work...\\n' $i; printf '[entry %03d] Nothing to do\\n' $i; done"
        )
        TestStep.wait(seconds: 2)

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 900, height: 1_000)

        TestStep.macClickButton(titled: "newline-bug")
        TestStep.wait(seconds: 2)

        // Initial mirror view — should show the latest entries at the bottom
        // of the pane with no blank rows between consecutive entries.
        TestStep.macScreenshot(label: "mac-initial-attach")

        // Scroll up to surface the rebuilt scrollback content. The bug
        // (when present) shows a blank row between every entry here.
        TestStep.macScrollUp(pages: 2)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-scrollback")
    }
}
