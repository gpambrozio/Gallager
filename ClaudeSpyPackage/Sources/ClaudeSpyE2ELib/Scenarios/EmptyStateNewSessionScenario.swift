import Foundation

/// E2E scenario: Verify the empty state shows a "New Session" button when no tmux sessions exist,
/// and that clicking it opens the new session popover and allows creating a terminal.
public enum EmptyStateNewSessionScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Empty State New Session",
        tags: ["terminal", "macos-only"]
    ) {
        // ── Setup ──────────────────────────────────────────────────
        // Do NOT create any tmux sessions — we want the empty state to show

        TestStep.launchMacApp
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)

        // ── Verify empty state ─────────────────────────────────────
        TestStep.log("Verifying empty state is shown with New Session button")
        TestStep.macWaitForElement(titled: "No Panes Available", timeout: 5)
        TestStep.macWaitForElement(titled: "New Session", timeout: 5)
        TestStep.macScreenshot(label: "empty-state", compare: false)

        // ── Click the New Session button ───────────────────────────
        TestStep.log("Clicking New Session button to open popover")
        TestStep.macClickButton(titled: "New Session")
        TestStep.wait(seconds: 2)

        // ── Verify popover content ─────────────────────────────────
        TestStep.macWaitForElement(titled: "New Terminal", timeout: 5)
        TestStep.macScreenshot(label: "new-session-popover", compare: false)

        // ── Create a new terminal session ──────────────────────────
        TestStep.log("Clicking New Terminal to create a session")
        TestStep.macClickButton(titled: "New Terminal")
        TestStep.wait(seconds: 3)

        // ── Verify the terminal was created ────────────────────────
        // The empty state should disappear once a pane exists
        TestStep.macWaitForElementToDisappear(titled: "No Panes Available", timeout: 10)
        // Positive assertion: verify the new pane target appears in the list
        TestStep.macWaitForElement(titled: "terminal:0.0", timeout: 5)
        TestStep.macScreenshot(label: "terminal-created", compare: false)
    }
}
