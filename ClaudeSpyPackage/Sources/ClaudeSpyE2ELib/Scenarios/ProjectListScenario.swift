import Foundation

/// E2E test that verifies the project scanner dependency wiring:
/// clicks the + button in the sidebar, then asserts mock projects appear.
/// macOS-only — no server or iOS needed.
public enum ProjectListScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Project List",
        tags: ["project-list", "macos-only"]
    ) {
        // ── Setup ──────────────────────────────────────────────────

        TestStep.log("Creating tmux session so sidebar has a section header with + button")
        TestStep.tmuxCreateSession(name: "project-test", width: 80, height: 24)

        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_000, height: 600)
        TestStep.macSetSidebarWidth(200)
        TestStep.wait(seconds: 1)

        // ── Click + button to open new session popover ───────────

        TestStep.log("Opening new session popover")
        TestStep.macClickButton(titled: "Create new session")
        TestStep.wait(seconds: 2)

        // ── Verify mock projects appear ──────────────────────────

        TestStep.log("Verifying mock projects are listed")
        TestStep.macWaitForElement(titled: "AlphaProject", timeout: 5)
        TestStep.macWaitForElement(titled: "BetaProject", timeout: 5)
        TestStep.macWaitForElement(titled: "GammaService", timeout: 5)
        TestStep.macWaitForElement(titled: "DeltaApp", timeout: 5)
        TestStep.macScreenshot(label: "project-list-mock-projects", compare: false)

        // ── Teardown ─────────────────────────────────────────────

        TestStep.terminateMacApp()
    }
}
