import Foundation

/// E2E scenario: Multi-window tabs on iOS
///
/// Verifies that tmux windows within a session work correctly on iOS:
/// 1. Create a session with two windows, each with identifiable content
/// 2. Navigate to the session on iOS — verify the active window is shown with prompt visible
/// 3. Switch to the other window via the title menu — verify content changes
/// 4. Go back to session list, re-enter — verify the tmux-active window is shown
public enum MultiWindowTabsIOSScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Multi Window Tabs iOS",
        tags: ["tabs", "ios"]
    ) {
        // ── Setup: Fresh pairing ─────────────────────────────────
        FreshPairingScenario.scenario

        // ── Stage 1: Create session with two windows ─────────────
        // Use 160x50 (large terminal) to test scroll position — the prompt
        // must be visible even when the terminal has more rows than the screen.

        TestStep.log("Stage 1: Create session with two windows (160x50)")
        TestStep.tmuxCreateSession(name: "ios-tabs", width: 160, height: 50)

        // Give windows deterministic names so menu items have predictable labels
        // (raw tmux's automatic-rename would otherwise track the running command).
        Shortcut.tmuxRunCommand(target: "ios-tabs:0.0", command: "tmux rename-window -t ios-tabs:0 'win0'")

        // Produce identifiable content in window 0
        Shortcut.tmuxRunCommand(target: "ios-tabs:0.0", command: "echo 'WINDOW_ZERO_CONTENT'")
        TestStep.wait(seconds: 1)

        // Create window 1 (becomes tmux-active) and name it
        Shortcut.tmuxRunCommand(target: "ios-tabs:0.0", command: "tmux new-window -t ios-tabs")
        TestStep.wait(seconds: 2)
        Shortcut.tmuxRunCommand(target: "ios-tabs:1.0", command: "tmux rename-window -t ios-tabs:1 'win1'")

        // Produce identifiable content in window 1
        Shortcut.tmuxRunCommand(target: "ios-tabs:1.0", command: "echo 'WINDOW_ONE_CONTENT'")
        TestStep.wait(seconds: 2)

        // Switch tmux back to window 0 so it's the active window
        Shortcut.tmuxRunCommand(target: "ios-tabs:1.0", command: "tmux select-window -t ios-tabs:0")
        // Wait long enough for the periodic pane refresh (every 10s) to detect the change
        TestStep.wait(seconds: 12)

        // ── Stage 2: Navigate to session on iOS ──────────────────

        TestStep.log("Stage 2: Open session on iOS — should show active window (0) with prompt visible")
        Shortcut.iosConnectToSession(sessionName: "ios-tabs")
        TestStep.wait(seconds: 3)

        // Screenshot + verify the iOS app is showing window 0 (status bar shows pane target)
        TestStep.iosScreenshot(label: "ios-initial-active-window")
        TestStep.iosWaitForElement(.labelContains("ios-tabs:0"), timeout: 5)

        // ── Stage 3: Switch to window 1 via title menu ───────────

        TestStep.log("Stage 3: Switch to window 1 via title menu")
        // Tap the navigation title menu (principal toolbar item with chevron)
        TestStep.iosTap(.labelContains("ios-tabs"))
        TestStep.wait(seconds: 1)

        // Tap window 1 in the menu (by its custom name "win1")
        TestStep.iosTap(.labelContains("win1"))
        TestStep.wait(seconds: 3)

        // Screenshot + verify the iOS app switched to window 1
        TestStep.iosScreenshot(label: "ios-switched-to-window-1")
        TestStep.iosWaitForElement(.labelContains("ios-tabs:1"), timeout: 5)

        // ── Stage 4: Verify macOS also switched to window 1 ──────

        TestStep.log("Stage 4: Open macOS panes window and verify window 1 is selected")
        Shortcut.openPanesWindow()
        TestStep.macResizeWindow(width: 1_200, height: 700)

        // Click the session in the sidebar — should show window 1 (tmux-active after iOS switch)
        TestStep.macWaitForElement(titled: "ios-tabs", timeout: 5)
        TestStep.macClickButton(titled: "ios-tabs")
        TestStep.wait(seconds: 3)

        // Screenshot — macOS should show window 1 content
        TestStep.macScreenshot(label: "mac-shows-window-1-after-ios-switch")
        // Verify the window 1 tab is selected on macOS
        TestStep.macWaitForElementQuery(.allOf([.labelContains("ios-tabs:1"), .valueContains("selected")]), timeout: 5)

        // ── Stage 5: Go back on iOS, switch tmux to window 0, re-enter ──

        TestStep.log("Stage 5: Go back to iOS session list, switch tmux to window 0, re-enter")
        TestStep.iosTap(.label("Sessions"))
        TestStep.wait(seconds: 2)

        // Switch tmux to window 0
        Shortcut.tmuxRunCommand(target: "ios-tabs:1.0", command: "tmux select-window -t ios-tabs:0")
        // Wait for pane refresh to propagate the active window change
        TestStep.wait(seconds: 12)

        // Re-enter the session on iOS
        TestStep.iosTap(.labelContains("ios-tabs"))
        TestStep.wait(seconds: 3)

        // Screenshot + verify the iOS app shows window 0
        TestStep.iosScreenshot(label: "ios-reenter-active-window-0")
        TestStep.iosWaitForElement(.labelContains("ios-tabs:0"), timeout: 5)

        // ── Stage 6: Go back on iOS, switch tmux to window 1, re-enter ──

        TestStep.log("Stage 6: Go back, switch tmux to window 1, re-enter")
        TestStep.iosTap(.label("Sessions"))
        TestStep.wait(seconds: 2)

        // Switch tmux to window 1
        Shortcut.tmuxRunCommand(target: "ios-tabs:0.0", command: "tmux select-window -t ios-tabs:1")
        // Wait for pane refresh
        TestStep.wait(seconds: 12)

        // Re-enter the session
        TestStep.iosTap(.labelContains("ios-tabs"))
        TestStep.wait(seconds: 3)

        // Screenshot + verify the iOS app shows window 1
        TestStep.iosScreenshot(label: "ios-reenter-active-window-1")
        TestStep.iosWaitForElement(.labelContains("ios-tabs:1"), timeout: 5)
    }
}
