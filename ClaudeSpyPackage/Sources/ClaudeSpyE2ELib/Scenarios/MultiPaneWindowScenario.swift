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
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "echo '=== PRIMARY PANE ==='")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "echo 'This is the original pane before any splits'")
        TestStep.wait(seconds: 1)

        // Launch macOS app and open Panes window
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        // Select the window and verify single-pane rendering
        TestStep.log("Verify sidebar shows 'multi-pane:0' and select it")
        TestStep.macWaitForElement(titled: "multi-pane", timeout: 5)
        TestStep.macClickButton(titled: "multi-pane")
        TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "single-pane")

        // ── Stage 2: Vertical split (left | right) ─────────────

        TestStep.log("Stage 2: Split vertically — creates left and right panes")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "tmux split-window -h")
        TestStep.wait(seconds: 1)

        // Send content to the new right pane
        Shortcut.tmuxRunCommand(target: "multi-pane:0.1", command: "echo '=== RIGHT PANE ==='")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.1", command: "echo 'Created by vertical split'")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "two-panes-vertical-split")

        // ── Stage 3: Horizontal split (right splits into top/bottom) ──

        TestStep.log("Stage 3: Split right pane horizontally — creates top-right and bottom-right")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.1", command: "tmux split-window -v")
        TestStep.wait(seconds: 1)

        // Send content to the new bottom-right pane
        Shortcut.tmuxRunCommand(target: "multi-pane:0.2", command: "echo '=== BOTTOM-RIGHT PANE ==='")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.2", command: "echo 'Created by horizontal split of right pane'")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "three-panes-final-layout")

        // ── Stage 4: More content in all panes ──────────────────

        TestStep.log("Stage 4: Add more content to all panes")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "echo 'Left pane still going strong'")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.1", command: "echo 'Top-right checking in'")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.2", command: "echo 'Bottom-right reporting for duty'")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "all-panes-with-extra-content")

        // ── Stage 5: Exit left pane (original, 3 → 2 panes) ─────

        TestStep.log("Stage 5: Exit left pane (first created) — layout should collapse to two panes")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "exit")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "two-panes-after-exit")

        // ── Stage 6: Exit top-right pane (second created, 2 → 1 pane) ──

        TestStep.log("Stage 6: Exit top-right pane (second created) — layout should collapse to single pane")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "exit")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "single-pane-after-exits")

        // ── Stage 7: Exit last pane (third created) — window disappears ──

        TestStep.log("Stage 7: Exit last pane — window should disappear from sidebar")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "exit")
        TestStep.wait(seconds: 3)

        // The window entry should vanish from the sidebar
        TestStep.macWaitForElementToDisappear(titled: "multi-pane", timeout: 10)
        // With no panes left, the app shows the "New Session" empty state
        TestStep.macWaitForElement(titled: "New Session", timeout: 5)
        TestStep.macScreenshot(label: "no-panes-empty-state")

        TestStep.macClickButton(titled: "New Terminal")
        TestStep.wait(seconds: 3)
        TestStep.macWaitForElement(titled: "terminal", timeout: 5)
        TestStep.macClickButton(titled: "terminal")
        TestStep.wait(seconds: 3)

        // Use session-relative targets (not global %N pane IDs which auto-increment)
        Shortcut.tmuxRunCommand(target: "terminal:0.0", command: "tmux split-window -h")
        TestStep.wait(seconds: 3)

        Shortcut.tmuxRunCommand(target: "terminal:0.1", command: "tmux split-window -v")
        TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "three-panes-new-session")

        Shortcut.tmuxRunCommand(target: "terminal:0.2", command: "exit")
        TestStep.wait(seconds: 3)

        Shortcut.tmuxRunCommand(target: "terminal:0.1", command: "exit")
        TestStep.wait(seconds: 3)

        Shortcut.tmuxRunCommand(target: "terminal:0.0", command: "echo 'Still here'")
        TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "last-should-have-echo")
    }
}
