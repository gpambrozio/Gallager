import Foundation

/// E2E scenario: Pair then create a new terminal session
public enum NewTerminalScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "New Terminal",
        tags: ["terminal", "smoke"]
    ) {
        // Reuse the full pairing flow (includes waitForHostConnected + waitForViewerConnected)
        FreshPairingScenario.scenario

        // 1. Tap the "+" button on the host header
        TestStep.iosTap(.label("New Session"))

        // 2. Wait for the project picker sheet to finish loading (an item
        //    appearing implies the spinner is gone — `waitForElementToDisappear`
        //    alone would return immediately if the spinner hadn't shown yet).
        TestStep.iosWaitForElement(.labelContains("New Terminal"), timeout: 15)
        TestStep.iosWaitForElementToDisappear(.labelContains("Loading projects"), timeout: 5)
        // Settle wait for sheet animation; row text is visible before the
        // sheet finishes transitioning, which leaves the baseline flaky.
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-new-session")

        // 3. Tap "New Terminal" in the project picker sheet
        TestStep.iosTap(.labelContains("New Terminal"))

        // 4. Verify the terminal view was pushed (WindowLayoutView shows a keyboard toggle)
        TestStep.iosWaitForElement(.labelContains("Show Keyboard"), timeout: 15)

        // 5. Verify the terminal connected (the "Connecting to terminal..." text should disappear)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting to terminal"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-new-terminal")
    }
}
