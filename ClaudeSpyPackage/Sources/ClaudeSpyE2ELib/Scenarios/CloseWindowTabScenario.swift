import Foundation

/// E2E scenario: Close window tab button and smart confirmation
///
/// Verifies that:
/// 1. An idle window can be closed via the X button without confirmation
/// 2. A window with a running process shows a confirmation dialog listing the process
/// 3. Pressing Escape cancels the confirmation and keeps the window open
/// 4. Closing an idle window removes the tab
/// 5. Closing a whole session with running processes via "Close Anyway" works
public enum CloseWindowTabScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Close Window Tab",
        tags: ["tabs", "macos-only"]
    ) {
        // 1. Create a session with two windows
        TestStep.log("Stage 1: Create session with two windows")
        TestStep.tmuxCreateSession(name: "closetest", width: 160, height: 50)
        Shortcut.tmuxClearAndSetPrompt(target: "closetest:0")
        Shortcut.tmuxRunCommand(target: "closetest:0.0", command: "echo '=== WINDOW 0 ==='")
        Shortcut.tmuxRunCommand(target: "closetest:0.0", command: "tmux new-window -t closetest")
        TestStep.wait(seconds: 1)
        Shortcut.tmuxClearAndSetPrompt(target: "closetest:1")
        Shortcut.tmuxRunCommand(target: "closetest:1.0", command: "echo '=== WINDOW 1 ==='")
        TestStep.wait(seconds: 1)

        // 2. Launch app and select the session
        TestStep.log("Stage 2: Launch app and verify two tabs")
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElement(titled: "closetest", timeout: 5)
        TestStep.macClickButton(titled: "closetest")
        TestStep.wait(seconds: 3)

        // Sidebar click selects the tmux-active window (window 1, since we just created it)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("closetest:1"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-two-tabs-before-close")

        // 3. Close the selected idle window 1 via the X button (no confirmation expected)
        TestStep.log("Stage 3: Close idle window 1 via X button")
        TestStep.macClickButton(titled: "Close window")
        TestStep.wait(seconds: 3)

        // Window 1 should be gone, only window 0 remains
        TestStep.macWaitForElementToDisappear(titled: "closetest:1", timeout: 5)
        TestStep.macScreenshot(label: "mac-after-idle-close")

        // 4. Run a process in the remaining window, then try to close
        TestStep.log("Stage 4: Run a process and try to close — should show confirmation")
        Shortcut.tmuxRunCommand(target: "closetest:0.0", command: "sleep 999")

        // Wait until tmux sees `sleep` as the pane's foreground command before
        // attempting the close. A fixed wait is racy on CI.
        TestStep.waitForTmuxDisplayMessage(
            target: "closetest:0.0",
            format: "#{pane_current_command}",
            contains: "sleep",
            timeout: 10
        )

        TestStep.macClickButton(titled: "Close window")
        TestStep.wait(seconds: 2)

        // Confirmation alert should appear with the process name
        TestStep.macWaitForElement(titled: "Close Window?", timeout: 5)
        TestStep.macScreenshot(label: "mac-close-confirmation-alert")

        // 5. Press Escape to cancel — window should remain
        TestStep.log("Stage 5: Press Escape to cancel the confirmation")
        TestStep.macPressKey(.escape)
        TestStep.wait(seconds: 2)

        // Tab should still be there
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("closetest:0"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-after-cancel")

        // 6. Kill the process so the window becomes idle, then close via X
        TestStep.log("Stage 6: Kill the process and close idle window")
        TestStep.tmuxSendKeys(target: "closetest:0", keys: "C-c")
        TestStep.wait(seconds: 2)

        // Now the window is idle — close should work without confirmation
        TestStep.macClickButton(titled: "Close window")
        TestStep.wait(seconds: 3)

        // Session should be gone since it was the last window
        TestStep.macWaitForElementToDisappear(titled: "closetest", timeout: 10)
        TestStep.macScreenshot(label: "mac-session-gone")

        // 7. Create a new session with a running process, close the whole session
        //    via context menu "Close Session" and confirm with "Close Anyway"
        TestStep.log("Stage 7: Close session with running process via Close Anyway")
        TestStep.tmuxCreateSession(name: "forceclose", width: 160, height: 50)
        Shortcut.tmuxClearAndSetPrompt(target: "forceclose:0")
        Shortcut.tmuxRunCommand(target: "forceclose:0.0", command: "sleep 999")

        // Wait until tmux sees `sleep` as the pane's foreground command before
        // attempting the close. A fixed wait is racy on CI.
        TestStep.waitForTmuxDisplayMessage(
            target: "forceclose:0.0",
            format: "#{pane_current_command}",
            contains: "sleep",
            timeout: 10
        )

        TestStep.macWaitForElement(titled: "forceclose", timeout: 5)
        TestStep.macClickButton(titled: "forceclose")
        TestStep.wait(seconds: 2)

        // Right-click sidebar → Close Session
        TestStep.macContextMenuClick(elementTitle: "forceclose", menuItem: "Close Session")
        TestStep.wait(seconds: 2)

        // Confirmation should appear since sleep is running
        TestStep.macWaitForElement(titled: "Close Session?", timeout: 5)
        TestStep.macScreenshot(label: "mac-close-session-confirmation")

        // "Close Anyway" is the default action — press Return to confirm
        TestStep.macPressKey(.return)
        TestStep.wait(seconds: 3)

        // Session should be gone despite the running process
        TestStep.macWaitForElementToDisappear(titled: "forceclose", timeout: 10)
        TestStep.macScreenshot(label: "mac-session-force-closed")
    }
}
