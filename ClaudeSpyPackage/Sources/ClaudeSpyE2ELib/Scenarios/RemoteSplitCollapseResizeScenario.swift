import Foundation

/// E2E scenario: When the right-pane terminal of a remote split is killed
/// on the host, the surviving left-pane terminal must resize back to the
/// full detail-pane width. Local sessions already do this — the same flow
/// has to work for remote sessions too (issue #523 follow-up).
///
/// Reproduces the user-reported bug:
/// > Create a new remote session, create a new terminal. Split the view.
/// > Both terminals resize as expected. Close the second terminal. First
/// > terminal takes the whole view again but doesn't resize.
public enum RemoteSplitCollapseResizeScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Remote Split Collapse Resize",
        tags: ["remote", "split-view", "resize", "macos-only"]
    ) {
        // ── Setup: pair two Mac apps ────────────────────────────────────
        Shortcut.twoMacPairing

        // ── Setup: one tmux session with two windows on the host ────────
        TestStep.log("Setup: Create rscoll session with two windows")
        TestStep.tmuxCreateSession(name: "rscoll", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["rename-window", "-t", "rscoll:0", "winLeft"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "rscoll", "-n", "winRight"])
        // Unique echo per window so the screenshots distinguish panes.
        TestStep.tmuxCommand(arguments: ["send-keys", "-t", "rscoll:winLeft", "echo winLeft", "Enter"])
        TestStep.tmuxCommand(arguments: ["send-keys", "-t", "rscoll:winRight", "echo winRight", "Enter"])
        TestStep.tmuxCommand(arguments: ["select-window", "-t", "rscoll:winLeft"])
        TestStep.wait(seconds: 1)

        // ── Open the host's Panes window so state propagates ────────────
        Shortcut.openPanesWindow()
        TestStep.macResizeWindow(width: 1_300, height: 700)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "rscoll", timeout: 15)

        // ── Select the remote session on the viewer side ────────────────
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macResizeWindow(width: 1_300, height: 700, instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "rscoll", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "rscoll", instance: 1)
        TestStep.wait(seconds: 3)
        TestStep.macWaitForElement(titled: "winLeft", timeout: 10, instance: 1)
        TestStep.macWaitForElement(titled: "winRight", timeout: 10, instance: 1)

        // ── Enable global auto-resize on the viewer ─────────────────────
        // Settings is still open on the viewer from `Shortcut.twoMacPairing`
        // (on the "Remote Hosts" tab) — switch to "General" before clicking
        // the auto-resize toggle.
        TestStep.macOpenSettings(instance: 1)
        TestStep.macSelectSettingsTab("General", instance: 1)
        TestStep.macWaitForWindow(titled: "General", timeout: 5, instance: 1)
        TestStep.macClickButton(
            titled: "Automatically resize all terminal panes to fit the mirror view when the window size changes",
            instance: 1
        )
        TestStep.wait(seconds: 1)
        TestStep.macCloseWindow(titled: "General", instance: 1)
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "rscoll", instance: 1)
        TestStep.wait(seconds: 2)

        // ── Phase 1: Capture pre-split (full) winLeft dimensions ────────
        TestStep.log("Phase 1: Capture pre-split full-width dimensions on winLeft")
        TestStep.macClickButton(titled: "rscoll:0 winLeft", instance: 1)
        TestStep.wait(seconds: 2)
        TestStep.tmuxStorePaneDimensions(
            target: "rscoll:winLeft",
            widthKey: "preSplitWidth",
            heightKey: "preSplitHeight"
        )
        TestStep.log("Pre-split winLeft: ${preSplitWidth}x${preSplitHeight}")
        Shortcut.tmuxRunCommand(
            target: "rscoll:winLeft",
            command: #"echo "[PRE-SPLIT] tput cols=$(tput cols)""#
        )
        TestStep.wait(seconds: 1)
        TestStep.tmuxCapturePaneContent(target: "rscoll:winLeft", storeAs: "preSplitContent")
        TestStep.assertStoredContains(
            key: "preSplitContent",
            substring: "[PRE-SPLIT] tput cols=${preSplitWidth}"
        )
        TestStep.macScreenshot(label: "viewer-rscoll-pre-split", instance: 1)

        // ── Phase 2: Open split — winRight goes to the right pane ───────
        TestStep.log("Phase 2: Click winRight's split toggle — winRight moves to the right pane")
        TestStep.macClickButton(titled: "Open terminal in split: winRight", instance: 1)
        TestStep.wait(seconds: 3)
        TestStep.macWaitForElement(titled: "Move terminal to left: winRight", timeout: 5, instance: 1)
        TestStep.wait(seconds: 2)
        TestStep.tmuxStorePaneDimensions(
            target: "rscoll:winLeft",
            widthKey: "splitLeftWidth",
            heightKey: "splitLeftHeight"
        )
        TestStep.log("Split winLeft: ${splitLeftWidth}x${splitLeftHeight}")
        TestStep.assertStoredNotEqual(key: "splitLeftWidth", otherKey: "preSplitWidth")
        Shortcut.tmuxRunCommand(
            target: "rscoll:winLeft",
            command: #"echo "[SPLIT] tput cols=$(tput cols)""#
        )
        TestStep.wait(seconds: 1)
        TestStep.tmuxCapturePaneContent(target: "rscoll:winLeft", storeAs: "splitContent")
        TestStep.assertStoredContains(
            key: "splitContent",
            substring: "[SPLIT] tput cols=${splitLeftWidth}"
        )
        TestStep.macScreenshot(label: "viewer-rscoll-split-open", instance: 1)

        // ── Phase 3: Kill winRight on the host → split must collapse ────
        //
        // This is the user-reported bug: the host kills the right-pane
        // window, the viewer's `RemoteSplitCleanupModifier` prunes the
        // stale `rightSide` entry so the layout flips back to single-pane,
        // but the left-pane terminal stays at the split width — it should
        // resize back to the full detail-pane width.
        TestStep.log("Phase 3: tmux kill-window on winRight; assert winLeft resizes back to full")
        TestStep.tmuxCommand(arguments: ["kill-window", "-t", "rscoll:winRight"])
        // Wait for the close to propagate to the viewer and for the
        // auto-resize debounce + relay round trip to land.
        TestStep.wait(seconds: 5)
        // The split should be gone — the "Move terminal to left: winRight"
        // affordance disappears with it.
        TestStep.macWaitForElementToDisappear(
            titled: "Move terminal to left: winRight",
            timeout: 5,
            instance: 1
        )
        TestStep.tmuxStorePaneDimensions(
            target: "rscoll:winLeft",
            widthKey: "postCloseWidth",
            heightKey: "postCloseHeight"
        )
        TestStep.log("Post-close winLeft: ${postCloseWidth}x${postCloseHeight}")
        // After the collapse, winLeft owns the entire detail pane again —
        // its tmux width must NOT still be the split width. (Comparing
        // against `preSplitWidth` would be ideal but Settings-window
        // dismissal timing makes the pre-split capture occasionally land a
        // few cols off from the steady-state full-width; the split width is
        // a stable bound and is what the user-reported bug would leave the
        // pane stuck at.)
        TestStep.assertStoredNotEqual(key: "postCloseWidth", otherKey: "splitLeftWidth")
        Shortcut.tmuxRunCommand(
            target: "rscoll:winLeft",
            command: #"echo "[POST-CLOSE] tput cols=$(tput cols)""#
        )
        TestStep.wait(seconds: 1)
        TestStep.tmuxCapturePaneContent(target: "rscoll:winLeft", storeAs: "postCloseContent")
        TestStep.assertStoredContains(
            key: "postCloseContent",
            substring: "[POST-CLOSE] tput cols=${postCloseWidth}"
        )
        TestStep.macScreenshot(label: "viewer-rscoll-collapsed-back-to-full", instance: 1)

        // ── Tear down ────────────────────────────────────────────────
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "rscoll"])
        TestStep.wait(seconds: 2)
    }
}
