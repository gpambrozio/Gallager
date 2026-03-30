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

        // Produce identifiable content in window 0
        Shortcut.tmuxRunCommand(target: "ios-tabs:0.0", command: "echo 'WINDOW_ZERO_CONTENT'")
        TestStep.wait(seconds: 1)

        // Create window 1 (becomes tmux-active)
        Shortcut.tmuxRunCommand(target: "ios-tabs:0.0", command: "tmux new-window -t ios-tabs")
        TestStep.wait(seconds: 2)

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

        // Take screenshot — should show WINDOW_ZERO_CONTENT with prompt visible
        TestStep.iosScreenshot(label: "ios-initial-active-window")

        // ── Stage 3: Switch to window 1 via title menu ───────────

        TestStep.log("Stage 3: Switch to window 1 via title menu")
        // Tap the navigation title (which has the toolbarTitleMenu chevron)
        TestStep.iosTap(.label("ios-tabs"))
        TestStep.wait(seconds: 1)

        // Tap window 1 in the menu
        TestStep.iosTap(.labelContains("1"))
        TestStep.wait(seconds: 3)

        // Take screenshot — should show WINDOW_ONE_CONTENT with prompt visible
        TestStep.iosScreenshot(label: "ios-switched-to-window-1")

        // ── Stage 4: Go back and re-enter ────────────────────────

        TestStep.log("Stage 4: Go back to session list and re-enter")
        TestStep.iosTap(.label("Sessions"))
        TestStep.wait(seconds: 2)

        // Switch tmux to window 1 to make it the active window
        Shortcut.tmuxRunCommand(target: "ios-tabs:0.0", command: "tmux select-window -t ios-tabs:1")
        // Wait for pane refresh to propagate the active window change
        TestStep.wait(seconds: 12)

        // Re-enter the session
        TestStep.iosTap(.labelContains("ios-tabs"))
        TestStep.wait(seconds: 3)

        // Should show window 1 (the tmux-active window), with WINDOW_ONE_CONTENT and prompt visible
        TestStep.iosScreenshot(label: "ios-reenter-active-window-1")
    }
}
