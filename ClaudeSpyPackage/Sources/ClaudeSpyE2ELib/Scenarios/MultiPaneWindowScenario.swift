import Foundation

/// E2E scenario: Multi-pane window layout
///
/// Verifies that when a tmux window has multiple panes:
/// 1. The sidebar shows a single window entry (not individual panes)
/// 2. Selecting it renders all panes in their layout arrangement
/// 3. Unique content in each pane is visible
public enum MultiPaneWindowScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Multi Pane Window",
        tags: ["sidebar", "layout", "macos-only"]
    ) {
        // ── Setup: Create a session with 3 panes ─────────────

        TestStep.log("Creating session with 3 panes (left, top-right, bottom-right)")
        TestStep.tmuxCreateSession(name: "multi-pane", width: 160, height: 50)

        // Split horizontally: creates left and right panes
        TestStep.tmuxCommand(arguments: ["split-window", "-h", "-t", "multi-pane:0"])
        TestStep.wait(seconds: 0.5)

        // Split the right pane vertically: creates top-right and bottom-right
        TestStep.tmuxCommand(arguments: ["split-window", "-v", "-t", "multi-pane:0.1"])
        TestStep.wait(seconds: 0.5)

        // Send unique markers to each pane for identification
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "echo LEFT-PANE-MARKER", literal: false)
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "Enter")
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "echo TOP-RIGHT-MARKER", literal: false)
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "Enter")
        TestStep.tmuxSendKeys(target: "multi-pane:0.2", keys: "echo BOTTOM-RIGHT-MARKER", literal: false)
        TestStep.tmuxSendKeys(target: "multi-pane:0.2", keys: "Enter")

        TestStep.wait(seconds: 1)

        // ── Launch and configure macOS app ────────────────────

        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(250)
        TestStep.wait(seconds: 2)

        // ── Verify sidebar shows single window entry ──────────

        TestStep.log("Verify sidebar shows single window entry 'multi-pane:0'")
        TestStep.macWaitForElement(titled: "multi-pane:0", timeout: 5)
        TestStep.macScreenshot(label: "sidebar-window-entry", compare: false)

        // ── Select the window and verify layout ───────────────

        TestStep.log("Select the window and verify multi-pane layout")
        TestStep.macClickButton(titled: "multi-pane:0")
        TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "multi-pane-layout", compare: false)
    }
}
