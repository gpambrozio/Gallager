import Foundation

/// E2E scenario: Verify the empty state shows "No Panes Available" with inline new session
/// options, and that clicking "New Terminal" creates a session and updates the sidebar.
public enum EmptyStateNewSessionScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Empty State New Session",
        tags: ["terminal", "macos-only"]
    ) {
        // ── Setup ──────────────────────────────────────────────────
        // Do NOT create any tmux sessions — we want the empty state to show.
        // The orchestrator kills the isolated tmux server between scenarios,
        // so we're guaranteed a clean slate here.

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 800)
        TestStep.macScreenshot(label: "mac-empty-state-start")

        // ── Verify empty state with new session options in detail ──
        TestStep.log("Verifying empty state shows No Panes Available in sidebar")
        TestStep.macWaitForElement(titled: "No Panes Available", timeout: 5)

        TestStep.log("Verifying New Terminal option is shown in detail area")
        TestStep.macWaitForElement(titled: "New Terminal", timeout: 5)

        TestStep.log("Verifying Claude Projects section is shown")
        TestStep.macWaitForElement(titled: "Claude Projects", timeout: 5)

        TestStep.macScreenshot(label: "mac-empty-state")

        // ── Click New Terminal and verify sidebar updates ────────
        TestStep.log("Clicking New Terminal to create a session")
        TestStep.macClickButton(titled: "New Terminal")
        TestStep.wait(seconds: 3)

        TestStep.log("Verifying empty state disappeared")
        TestStep.macWaitForElementToDisappear(titled: "No Panes Available", timeout: 10)

        TestStep.log("Verifying Local section appeared in sidebar")
        TestStep.macWaitForElement(titled: "Local", timeout: 10)

        TestStep.macScreenshot(label: "mac-terminal-created")

        // ── Close session and verify empty state returns ─────
        // No running processes → closes immediately without confirmation dialog
        TestStep.log("Clicking Close session toolbar button")
        TestStep.macClickButton(titled: "Close session")
        TestStep.wait(seconds: 2)

        TestStep.log("Verifying empty state returned")
        TestStep.macWaitForElement(titled: "No Panes Available", timeout: 10)

        TestStep.log("Verifying New Session options returned in detail area")
        TestStep.macWaitForElement(titled: "New Terminal", timeout: 5)

        TestStep.macScreenshot(label: "mac-empty-state-after-close")
    }
}
