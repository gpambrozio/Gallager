import Foundation

/// E2E scenario: Multi-pane window layout (progressive splits)
///
/// Builds a multi-pane tmux window step-by-step, verifying at each stage:
/// 1. Single pane — sidebar shows the window, terminal renders output
/// 2. Vertical split — two panes side-by-side, each with unique content
/// 3. Horizontal split — three panes in an L-shaped layout, all visible
public enum MultiPaneWindowScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Multi Pane Window",
        tags: ["sidebar", "layout", "macos-only"]
    ) {
        // ── Stage 1: Single-pane session ────────────────────────

        TestStep.log("Stage 1: Create session with a single pane")
        TestStep.tmuxCreateSession(name: "multi-pane", width: 160, height: 50)

        // Produce some output so the terminal isn't empty
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "echo '=== PRIMARY PANE ==='", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "Enter")
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "echo 'This is the original pane before any splits'", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // Launch macOS app and open Panes window
        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Available Windows", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(250)
        TestStep.wait(seconds: 2)

        // Select the window and verify single-pane rendering
        TestStep.log("Verify sidebar shows 'multi-pane:0' and select it")
        TestStep.macWaitForElement(titled: "multi-pane:0", timeout: 5)
        TestStep.macClickButton(titled: "multi-pane:0")
        TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "single-pane")

        // ── Stage 2: Vertical split (left | right) ─────────────

        TestStep.log("Stage 2: Split vertically — creates left and right panes")
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "tmux split-window -h", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // Send content to the new right pane
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "echo '=== RIGHT PANE ==='", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "Enter")
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "echo 'Created by vertical split'", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "Enter")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "two-panes-vertical-split")

        // ── Stage 3: Horizontal split (right splits into top/bottom) ──

        TestStep.log("Stage 3: Split right pane horizontally — creates top-right and bottom-right")
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "tmux split-window -v", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "Enter")
        TestStep.wait(seconds: 1)

        // Send content to the new bottom-right pane
        TestStep.tmuxSendKeys(target: "multi-pane:0.2", keys: "echo '=== BOTTOM-RIGHT PANE ==='", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.2", keys: "Enter")
        TestStep.tmuxSendKeys(target: "multi-pane:0.2", keys: "echo 'Created by horizontal split of right pane'", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.2", keys: "Enter")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "three-panes-final-layout")

        // ── Stage 4: More content in all panes ──────────────────

        TestStep.log("Stage 4: Add more content to all panes")
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "echo 'Left pane still going strong'", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "Enter")
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "echo 'Top-right checking in'", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.1", keys: "Enter")
        TestStep.tmuxSendKeys(target: "multi-pane:0.2", keys: "echo 'Bottom-right reporting for duty'", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.2", keys: "Enter")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "all-panes-with-extra-content")

        // ── Stage 5: Exit left pane (original, 3 → 2 panes) ─────

        TestStep.log("Stage 5: Exit left pane (first created) — layout should collapse to two panes")
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "exit", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "Enter")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "two-panes-after-exit")

        // ── Stage 6: Exit top-right pane (second created, 2 → 1 pane) ──

        TestStep.log("Stage 6: Exit top-right pane (second created) — layout should collapse to single pane")
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "exit", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "Enter")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "single-pane-after-exits")

        // ── Stage 7: Exit last pane (third created) — window disappears ──

        TestStep.log("Stage 7: Exit last pane — window should disappear from sidebar")
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "exit", literal: true)
        TestStep.tmuxSendKeys(target: "multi-pane:0.0", keys: "Enter")
        TestStep.wait(seconds: 3)

        // The window entry should vanish from the sidebar
        TestStep.macWaitForElementToDisappear(titled: "multi-pane:0", timeout: 10)
        // With no panes left, the app shows the "New Session" empty state
        TestStep.macWaitForElement(titled: "New Session", timeout: 5)
        TestStep.macScreenshot(label: "no-panes-empty-state")

        TestStep.macClickButton(titled: "New Terminal")
        TestStep.macWaitForElement(titled: "terminal:1", timeout: 5)
        TestStep.macClickButton(titled: "terminal:1")
        TestStep.wait(seconds: 3)

        TestStep.tmuxSendKeys(target: "%0", keys: "tmux split-window -h", literal: true)
        TestStep.tmuxSendKeys(target: "%0", keys: "Enter")
        TestStep.wait(seconds: 3)

        TestStep.tmuxSendKeys(target: "%1", keys: "tmux split-window -v", literal: true)
        TestStep.tmuxSendKeys(target: "%1", keys: "Enter")
        TestStep.wait(seconds: 3)

        TestStep.tmuxSendKeys(target: "%2", keys: "exit", literal: true)
        TestStep.tmuxSendKeys(target: "%2", keys: "Enter")
        TestStep.wait(seconds: 3)

        TestStep.tmuxSendKeys(target: "%1", keys: "exit", literal: true)
        TestStep.tmuxSendKeys(target: "%1", keys: "Enter")
        TestStep.wait(seconds: 3)

        // TestStep.tmuxSendKeys(target: "%0", keys: "echo 'Still here'", literal: true)
        // TestStep.tmuxSendKeys(target: "%0", keys: "Enter")
        // TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "last-should-have-echo")
    }
}
