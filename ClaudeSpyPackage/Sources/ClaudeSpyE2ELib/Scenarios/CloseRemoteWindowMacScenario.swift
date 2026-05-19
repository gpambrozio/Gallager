import Foundation

/// E2E scenario: Close remote window/session from Mac viewer
///
/// Verifies that the Mac viewer can close tmux windows and sessions
/// on a remote host:
/// 1. Create a session with two windows on the host
/// 2. Viewer closes an idle window via the tab bar X button — no confirmation
/// 3. Run a process in the remaining window, close the session via toolbar
/// 4. Confirmation alert appears listing the running process
/// 5. Click "Close Anyway" — session is killed on the host
public enum CloseRemoteWindowMacScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Close Remote Window Mac Viewer",
        tags: ["tabs", "macos-only", "remote"]
    ) {
        // 1. Pair two Mac apps (host=0, viewer=1)
        Shortcut.twoMacPairing

        // 2. Create a session with two named windows
        TestStep.log("Phase 1: Create session with two windows")
        TestStep.tmuxCreateSession(name: "mac-close", width: 80, height: 24)
        Shortcut.tmuxClearAndSetPrompt(target: "mac-close:0")
        Shortcut.tmuxRunCommand(target: "mac-close:0.0", command: "tmux rename-window -t mac-close:0 'main'")
        Shortcut.tmuxRunCommand(target: "mac-close:0.0", command: "echo 'WINDOW_ZERO'")
        Shortcut.tmuxRunCommand(target: "mac-close:0.0", command: "tmux new-window -t mac-close")
        TestStep.wait(seconds: 1)
        Shortcut.tmuxClearAndSetPrompt(target: "mac-close:1")
        Shortcut.tmuxRunCommand(target: "mac-close:1.0", command: "tmux rename-window -t mac-close:1 'other'")
        Shortcut.tmuxRunCommand(target: "mac-close:1.0", command: "echo 'WINDOW_ONE'")
        // Switch tmux back to window 0
        Shortcut.tmuxRunCommand(target: "mac-close:1.0", command: "tmux select-window -t mac-close:0")

        // 3. Host opens panes window and selects the session
        TestStep.log("Phase 2: Host opens panes window")
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "mac-close", timeout: 10)
        TestStep.macClickButton(titled: "mac-close")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("mac-close:0"), .valueContains("selected")]),
            timeout: 5
        )

        // 4. Viewer opens panes window and selects the session
        TestStep.log("Phase 3: Viewer opens panes window and selects session")
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macResizeWindow(width: 1_200, height: 700, instance: 1)

        TestStep.macWaitForElement(titled: "mac-close", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "mac-close", instance: 1)

        // Verify both tabs are visible on viewer
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("mac-close:0"), .valueContains("selected")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-two-tabs", instance: 1)

        // 5. Switch to window 1 on viewer, then close it via X button
        TestStep.log("Phase 4: Switch to window 1 and close via X button")
        TestStep.macClickButton(titled: "mac-close:1", instance: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("mac-close:1"), .valueContains("selected")]),
            timeout: 5,
            instance: 1
        )

        // Close the selected window via the X button (no confirmation — idle window)
        TestStep.macClickButton(titled: "Close window", instance: 1)

        // Window 1 should be gone, viewer should show window 0
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("mac-close:1"),
            timeout: 10,
            instance: 1
        )
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("mac-close:0"), .valueContains("selected")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("WINDOW_ZERO")]),
            timeout: 10,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-after-window-close", instance: 1)

        // Verify host also shows only window 0
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("mac-close:1"),
            timeout: 10
        )
        TestStep.macScreenshot(label: "host-after-window-close")

        // 6. Run a process in the remaining window, then close the session
        TestStep.log("Phase 5: Run process and close session — should show confirmation")
        Shortcut.tmuxRunCommand(target: "mac-close:0.0", command: "sleep 999")

        // Wait until tmux sees `sleep` as the pane's foreground command. A fixed 2s
        // wait is racy on CI — the shell may not have executed `sleep` yet, in which
        // case the host's CheckRunningProcesses returns an empty list and the alert
        // never appears (close happens without confirmation).
        TestStep.waitForTmuxDisplayMessage(
            target: "mac-close:0.0",
            format: "#{pane_current_command}",
            contains: "sleep",
            timeout: 10
        )

        // Close session via toolbar button
        TestStep.macClickButton(titled: "Close session", instance: 1)

        // Confirmation alert should appear
        TestStep.macWaitForElement(titled: "Close Session?", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-close-session-confirmation", instance: 1)

        // 7. Confirm with "Close Anyway" (default action — press Return)
        TestStep.log("Phase 6: Confirm close — session should be killed")
        TestStep.macPressKey(.return, instance: 1)

        // Session should be gone from both host and viewer
        TestStep.macWaitForElementToDisappear(titled: "mac-close", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-session-gone", instance: 1)

        TestStep.macWaitForElementToDisappear(titled: "mac-close", timeout: 10)
        TestStep.macScreenshot(label: "host-session-gone")
    }
}
