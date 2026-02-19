import Foundation

/// E2E test for the macOS project search field:
/// Opens the new session popover, types in the search field, and verifies filtering works.
public enum ProjectSearchMacOSScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Project Search macOS",
        tags: ["project-search", "macos-only"]
    ) {
        // ── Setup ──────────────────────────────────────────────────
        TestStep.log("Creating tmux session so sidebar has a section header with + button")
        TestStep.tmuxCreateSession(name: "search-test", width: 80, height: 24)

        TestStep.launchMacApp
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)

        // ── Open new session popover ─────────────────────────────
        TestStep.log("Opening new session popover")
        TestStep.macClickButton(titled: "Create new session")
        TestStep.wait(seconds: 2)

        // ── Verify all mock projects appear ──────────────────────
        TestStep.log("Verifying all mock projects are listed")
        TestStep.macWaitForElement(titled: "AlphaProject", timeout: 5)
        TestStep.macWaitForElement(titled: "BetaProject", timeout: 5)
        TestStep.macWaitForElement(titled: "GammaService", timeout: 5)
        TestStep.macWaitForElement(titled: "DeltaApp", timeout: 5)
        TestStep.macScreenshot(label: "all-projects-visible", compare: false)

        // ── Type fuzzy search to filter projects ────────────────
        TestStep.log("Typing 'alpr' to test fuzzy/subsequence matching")
        TestStep.macType(text: "alpr")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "fuzzy-search-filtered", compare: false)

        // AlphaProject should still be visible, others should be filtered out
        TestStep.macWaitForElement(titled: "AlphaProject", timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "BetaProject", timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "GammaService", timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "DeltaApp", timeout: 5)

        // ── Press return to select the single result ────────────
        TestStep.log("Pressing return to select AlphaProject")
        TestStep.macType(text: "", pressReturn: true)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "AlphaProject", timeout: 5)
        TestStep.macScreenshot(label: "project-selected", compare: false)

        // ── Teardown ─────────────────────────────────────────────
        TestStep.terminateMacApp
    }
}
