import Foundation

/// E2E scenario: Close remote window/session from iOS viewer
///
/// Verifies that the iOS remote viewer can close tmux windows and sessions
/// on the host via the window switcher menu:
/// 1. Create a session with two named windows, navigate to it on iOS
/// 2. Close an idle window via the title menu — should close without confirmation
/// 3. Run a process in the remaining window, try to close the session
/// 4. Confirmation alert appears listing the running process
/// 5. Tap "Close Anyway" — session is killed on the host
public enum CloseRemoteWindowIOSScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Close Remote Window iOS",
        tags: ["tabs", "ios", "remote"]
    ) {
        // 1. Fresh pairing setup
        FreshPairingScenario.scenario

        // 2. Create a session with two named windows
        TestStep.log("Stage 1: Create session with two windows")
        TestStep.tmuxCreateSession(name: "ios-close", width: 120, height: 40)
        Shortcut.tmuxClearAndSetPrompt(target: "ios-close:0")
        // Rename windows for predictable menu labels
        Shortcut.tmuxRunCommand(target: "ios-close:0.0", command: "tmux rename-window -t ios-close:0 'main'")
        Shortcut.tmuxRunCommand(target: "ios-close:0.0", command: "tmux new-window -t ios-close")
        TestStep.wait(seconds: 1)
        Shortcut.tmuxClearAndSetPrompt(target: "ios-close:1")
        Shortcut.tmuxRunCommand(target: "ios-close:1.0", command: "tmux rename-window -t ios-close:1 'other'")

        // Switch tmux to window 0 so it's the active window
        Shortcut.tmuxRunCommand(target: "ios-close:1.0", command: "tmux select-window -t ios-close:0")
        TestStep.wait(seconds: 12)

        // 3. Navigate to the session on iOS
        TestStep.log("Stage 2: Navigate to session on iOS")
        Shortcut.iosConnectToSession(sessionName: "ios-close")

        // Verify we're on window 0
        TestStep.iosWaitForElement(.labelContains("ios-close:0"), timeout: 5)

        // 4. Switch to window 1, then close it (idle window — no confirmation expected)
        TestStep.log("Stage 3: Switch to window 1 and close it via menu")
        // Tap navigation title to open window switcher menu
        TestStep.iosTap(.labelContains("ios-close"))
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-window-menu-two-windows")
        // Tap window 1 ("other") in the menu — label is the window name only
        TestStep.iosTap(.labelContains("other"))
        TestStep.iosWaitForElement(.labelContains("ios-close:1"), timeout: 5)

        // Open menu again and tap "Close Window"
        TestStep.iosTap(.labelContains("ios-close"))
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-window-menu-close-option")
        TestStep.iosTap(.label("Close Window"))

        // Window 1 should be gone, should be back on window 0
        TestStep.iosWaitForElement(.labelContains("ios-close:0"), timeout: 10)
        // Wait for terminal to reconnect (may show transient "Connecting" or "Stream Error")
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
        TestStep.iosWaitForElementToDisappear(.labelContains("Window Not Found"), timeout: 15)
        TestStep.wait(seconds: 3)
        TestStep.iosScreenshot(label: "ios-after-window-close")

        // 5. Run a process in the remaining window, then try to close the session
        TestStep.log("Stage 4: Run process and try to close session — should show confirmation")
        Shortcut.tmuxRunCommand(target: "ios-close:0.0", command: "sleep 999")

        // Wait until tmux sees `sleep` as the pane's foreground command. A fixed 2s
        // wait is racy on CI — the shell may not have executed `sleep` yet, in which
        // case the host's CheckRunningProcesses returns an empty list and the alert
        // either doesn't appear or doesn't mention sleep.
        TestStep.waitForTmuxDisplayMessage(
            target: "ios-close:0.0",
            format: "#{pane_current_command}",
            contains: "sleep",
            timeout: 10
        )

        TestStep.iosTap(.labelContains("ios-close"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Close Session"))

        // Confirmation alert should appear with process info
        TestStep.iosWaitForElement(.labelContains("Close Session"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("sleep"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-close-session-confirmation")

        // 6. Confirm by tapping "Close Anyway"
        TestStep.log("Stage 5: Confirm close — session should be killed")
        TestStep.iosTap(.roleAndLabelContains(role: "Button", label: "Close Anyway"))

        // After session is killed, the view should auto-dismiss to the session list
        TestStep.iosWaitForElement(.labelContains("Sessions"), timeout: 30)
        TestStep.iosWaitForElementToDisappear(.labelContains("ios-close"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-session-list-after-close")
    }
}
