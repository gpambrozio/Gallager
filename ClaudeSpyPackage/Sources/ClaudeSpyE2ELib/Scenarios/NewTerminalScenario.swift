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
        TestStep.wait(seconds: 2)

        // 2. Verify projects loaded (the "Loading projects..." spinner should disappear)
        TestStep.iosWaitForElementToDisappear(.labelContains("Loading projects"), timeout: 15)
        TestStep.iosScreenshot(label: "02.1-new-session")

        // 3. Tap "New Terminal" in the project picker sheet
        TestStep.iosTap(.labelContains("New Terminal"))
        TestStep.wait(seconds: 2)

        // 4. Verify the terminal view was pushed
        TestStep.iosWaitForElement(.labelContains("Terminal"), timeout: 15)

        // 5. Verify the terminal connected (the "Connecting to terminal..." text should disappear)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting to terminal"), timeout: 15)
        TestStep.iosScreenshot(label: "02.2-new-terminal")
    }
}
