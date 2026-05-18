import Foundation

/// E2E test for the iOS project search field:
/// Pairs devices, opens the project picker sheet, uses the search field to filter projects.
public enum ProjectSearchIOSScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Project Search iOS",
        tags: ["project-search", "ios"]
    ) {
        // ── Setup: Full pairing flow ─────────────────────────────
        FreshPairingScenario.scenario

        // ── Open project picker sheet ────────────────────────────
        TestStep.log("Opening project picker sheet")
        TestStep.iosTap(.label("New Session"))

        // ── Verify all mock projects appear ──────────────────────
        // (waiting for the project items implies the loading spinner is gone)
        TestStep.log("Verifying all mock projects are listed")
        TestStep.iosWaitForElement(.labelContains("AlphaProject"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("BetaProject"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("GammaService"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("DeltaApp"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-all-projects-visible")

        // ── Tap search field and type fuzzy search ────────────────
        TestStep.log("Tapping search field and typing 'alpr' to test fuzzy/subsequence matching")
        TestStep.iosTap(.role("SearchField"))
        TestStep.iosType(text: "alpr")

        // AlphaProject should still be visible, others should be filtered out
        TestStep.iosWaitForElement(.labelContains("AlphaProject"), timeout: 5)
        TestStep.iosWaitForElementToDisappear(.labelContains("BetaProject"), timeout: 5)
        TestStep.iosWaitForElementToDisappear(.labelContains("GammaService"), timeout: 5)
        TestStep.iosWaitForElementToDisappear(.labelContains("DeltaApp"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-fuzzy-search-filtered")

        // ── Press return to select the single result ────────────
        TestStep.log("Pressing return to select AlphaProject")
        TestStep.iosType(text: "\n")
        // Check the sheet closed by verifying a sheet-only element is gone.
        // "AlphaProject" can't be used here because it appears in the session list
        // as the newly created session's project label.
        TestStep.iosWaitForElementToDisappear(.labelContains("Search projects"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-project-selected", compare: false)

        // ── Teardown ─────────────────────────────────────────────
        TestStep.terminateMacApp()
        TestStep.terminateIOSApp
        TestStep.stopServer
    }
}
