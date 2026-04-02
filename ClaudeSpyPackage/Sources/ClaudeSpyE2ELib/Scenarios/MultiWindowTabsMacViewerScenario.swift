import Foundation

/// E2E scenario: Multi-window tabs on a Mac viewer
///
/// Verifies that the RemoteWindowTabBar works correctly on a Mac-to-Mac viewer:
/// 1. Create a session with two windows on the host, each with identifiable content
/// 2. Host opens panes window and selects the session (window 0 active)
/// 3. Viewer connects and sees the tab bar with window 0 selected
/// 4. Switch to window 1 via the viewer's tab bar — verify host tab also updates
/// 5. Create a 3rd window via the "+" button
/// 6. Switch back to window 1 and verify content
/// 7. Verify the host reflects the viewer's window selection
/// 8. Close window 1 from the host, verify only 2 tabs remain on both
public enum MultiWindowTabsMacViewerScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Multi Window Tabs Mac Viewer",
        tags: ["tabs", "macos-only"]
    ) {
        // ── Setup: Pair two Mac apps ─────────────────────────────
        Shortcut.twoMacPairing

        // ── Phase 1: Create session with 2 windows on host ──────
        TestStep.log("Phase 1: Create session with two windows")
        TestStep.tmuxCreateSession(name: "e2e-mw-mac", width: 80, height: 24)

        // Produce identifiable content in window 0
        Shortcut.tmuxRunCommand(target: "e2e-mw-mac:0.0", command: "echo 'WINDOW_ZERO'")
        TestStep.wait(seconds: 1)

        // Create window 1 (becomes tmux-active)
        Shortcut.tmuxRunCommand(target: "e2e-mw-mac:0.0", command: "tmux new-window -t e2e-mw-mac")
        TestStep.wait(seconds: 2)

        // Produce identifiable content in window 1
        Shortcut.tmuxRunCommand(target: "e2e-mw-mac:1.0", command: "echo 'WINDOW_ONE'")
        TestStep.wait(seconds: 2)

        // Switch tmux back to window 0
        Shortcut.tmuxRunCommand(target: "e2e-mw-mac:1.0", command: "tmux select-window -t e2e-mw-mac:0")

        // ── Phase 2: Open host panes window and select session ──
        // Opening the panes window triggers a pane refresh, no need to wait for periodic refresh
        TestStep.log("Phase 2: Open host panes window and select session")
        Shortcut.openPanesWindow()

        TestStep.macWaitForElement(titled: "e2e-mw-mac", timeout: 10)
        TestStep.macClickButton(titled: "e2e-mw-mac")
        TestStep.wait(seconds: 3)

        // Host should show window 0 selected (tmux-active)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("e2e-mw-mac:0"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-%0"), .valueContains("WINDOW_ZERO")]), timeout: 10)
        TestStep.macScreenshot(label: "host-window0-selected")

        // ── Phase 3: Viewer connects and sees tab bar ───────────
        TestStep.log("Phase 3: Viewer opens panes window and selects session")
        Shortcut.openPanesWindow(instance: 1)

        TestStep.macWaitForElement(titled: "e2e-mw-mac", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "e2e-mw-mac", instance: 1)
        TestStep.wait(seconds: 3)

        // Verify window 0 tab is selected on viewer
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("e2e-mw-mac:0"), .valueContains("selected")]),
            timeout: 5,
            instance: 1
        )
        // Wait for terminal to render window 0 content (pane %0)
        TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-%0"), .valueContains("WINDOW_ZERO")]), timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-window0-selected", instance: 1)

        // ── Phase 4: Switch to window 1 via viewer tab bar ──────
        TestStep.log("Phase 4: Click window 1 tab on viewer and verify host follows")
        TestStep.macClickButton(titled: "e2e-mw-mac:1", instance: 1)
        TestStep.wait(seconds: 3)

        // Verify window 1 is now selected on viewer
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("e2e-mw-mac:1"), .valueContains("selected")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-%1"), .valueContains("WINDOW_ONE")]), timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-window1-selected", instance: 1)

        // Verify host tab also updated to window 1 (synced via tmux active window)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("e2e-mw-mac:1"), .valueContains("selected")]),
            timeout: 15
        )
        TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-%1"), .valueContains("WINDOW_ONE")]), timeout: 10)
        TestStep.macScreenshot(label: "host-follows-viewer-to-window1")

        // ── Phase 5: Create 3rd window via "+" button ───────────
        TestStep.log("Phase 5: Create new window via + button")
        TestStep.macClickButton(titled: "New Window", instance: 1)
        TestStep.wait(seconds: 5)

        // Verify new tab appears and is auto-selected
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("e2e-mw-mac:2"), .valueContains("selected")]),
            timeout: 10,
            instance: 1
        )
        // Produce identifiable content in window 2
        Shortcut.tmuxRunCommand(target: "e2e-mw-mac:2.0", command: "echo 'WINDOW_TWO'")
        // Wait for terminal to render window 2 content (pane %2)
        TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-%2"), .valueContains("WINDOW_TWO")]), timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-window2-created", instance: 1)

        // ── Phase 6: Switch back to window 1 ────────────────────
        TestStep.log("Phase 6: Switch back to window 1 and verify content")
        TestStep.macClickButton(titled: "e2e-mw-mac:1", instance: 1)
        TestStep.wait(seconds: 3)

        // Verify content in window 1 (both via tmux and terminal view)
        TestStep.tmuxCapturePaneContent(target: "e2e-mw-mac:1", storeAs: "paneContent")
        TestStep.assertStoredContains(key: "paneContent", substring: "WINDOW_ONE")
        TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-%1"), .valueContains("WINDOW_ONE")]), timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-back-to-window1", instance: 1)

        // ── Phase 7: Verify host reflects viewer's selection ────
        TestStep.log("Phase 7: Verify host shows window 1 selected")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("e2e-mw-mac:1"), .valueContains("selected")]),
            timeout: 15
        )
        TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-%1"), .valueContains("WINDOW_ONE")]), timeout: 10)
        TestStep.macScreenshot(label: "host-reflects-window1")

        // ── Phase 8: Close window 1 via "exit", verify 2 tabs ───
        TestStep.log("Phase 8: Exit window 1 shell and verify tab removal")
        Shortcut.tmuxRunCommand(target: "e2e-mw-mac:1.0", command: "exit")
        TestStep.wait(seconds: 5)

        // Verify window 1 tab is gone on host and terminal renders content
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("e2e-mw-mac:1"),
            timeout: 10
        )
        TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-%2"), .valueContains("WINDOW_TWO")]), timeout: 5)
        TestStep.macScreenshot(label: "host-after-window-close")

        // Verify window 1 tab is gone on viewer too and terminal renders content
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("e2e-mw-mac:1"),
            timeout: 10,
            instance: 1
        )
        TestStep.macWaitForElementQuery(.allOf([.identifier("terminal-%2"), .valueContains("WINDOW_TWO")]), timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-after-window-close", instance: 1)
    }
}
