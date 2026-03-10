import Foundation

/// E2E scenario: Multi-pane window display
///
/// Verifies that when a tmux window has multiple panes:
/// 1. The sidebar shows the window (not individual panes)
/// 2. Selecting the window shows all panes in a layout
/// 3. Each pane displays its own content independently
public enum MultiPaneWindowScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Multi-Pane Window",
        tags: ["panes", "layout", "macos-only"]
    ) {
        // ── Setup ──────────────────────────────────────────────────

        TestStep.log("Creating tmux session with multiple panes")
        TestStep.tmuxCreateSession(name: "multi-pane", width: 120, height: 40)
        TestStep.wait(seconds: 0.5)

        // Split horizontally (creates a second pane to the right)
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "tmux split-window -h", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // Split the right pane vertically (creates a third pane below the right pane)
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "tmux split-window -v", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "Enter")
        TestStep.wait(seconds: 1)

        // Put unique markers in each pane so we can verify content
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "echo '=== PANE-LEFT ==='", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "Enter")
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "echo '=== PANE-TOP-RIGHT ==='", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "Enter")
        TestStep.tmuxSendKeys(target: "multi-pane:0.2", keys: "echo '=== PANE-BOTTOM-RIGHT ==='", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.2", keys: "Enter")
        TestStep.wait(seconds: 0.5)

        // Verify pane content was set correctly
        TestStep.tmuxCapturePaneContent(target: "multi-pane:0.0", storeAs: "pane0Content")
        TestStep.assertStoredContains(key: "pane0Content", substring: "PANE-LEFT")
        TestStep.tmuxCapturePaneContent(target: "multi-pane:0.1", storeAs: "pane1Content")
        TestStep.assertStoredContains(key: "pane1Content", substring: "PANE-TOP-RIGHT")
        TestStep.tmuxCapturePaneContent(target: "multi-pane:0.2", storeAs: "pane2Content")
        TestStep.assertStoredContains(key: "pane2Content", substring: "PANE-BOTTOM-RIGHT")

        // ── Launch App ─────────────────────────────────────────────

        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_200, height: 800)
        TestStep.macSetSidebarWidth(250)
        TestStep.wait(seconds: 1)

        // ── Phase 1: Verify window appears in sidebar ──────────────

        TestStep.log("Phase 1: Window should appear in sidebar as a single entry")

        // The window should appear as "multi-pane:0" (window ID, not pane target)
        TestStep.macWaitForElement(titled: "multi-pane:0", timeout: 10)
        TestStep.macScreenshot(label: "window-in-sidebar")

        // ── Phase 2: Select window and verify layout ───────────────

        TestStep.log("Phase 2: Select window and verify multi-pane layout")
        TestStep.macClickButton(titled: "multi-pane:0")
        TestStep.wait(seconds: 3)

        // Take screenshot showing the multi-pane layout
        TestStep.macScreenshot(label: "multi-pane-layout")

        // ── Phase 3: Verify pane dimensions confirm split ──────────

        TestStep.log("Phase 3: Verify pane dimensions show proper split")

        // Left pane should have different width than right panes
        TestStep.tmuxStorePaneDimensions(
            target: "multi-pane:0.0",
            widthKey: "leftWidth",
            heightKey: "leftHeight"
        )
        TestStep.tmuxStorePaneDimensions(
            target: "multi-pane:0.1",
            widthKey: "topRightWidth",
            heightKey: "topRightHeight"
        )
        TestStep.tmuxStorePaneDimensions(
            target: "multi-pane:0.2",
            widthKey: "bottomRightWidth",
            heightKey: "bottomRightHeight"
        )

        TestStep.log("Left pane: ${leftWidth}x${leftHeight}")
        TestStep.log("Top-right pane: ${topRightWidth}x${topRightHeight}")
        TestStep.log("Bottom-right pane: ${bottomRightWidth}x${bottomRightHeight}")

        // Right panes should have same width (they share a vertical split)
        TestStep.assertStoredEqual(key: "topRightWidth", otherKey: "bottomRightWidth")
        // Right panes should have different height than left pane (vertical split)
        TestStep.assertStoredNotEqual(key: "topRightHeight", otherKey: "leftHeight")

        TestStep.macScreenshot(label: "multi-pane-verified")
    }
}
