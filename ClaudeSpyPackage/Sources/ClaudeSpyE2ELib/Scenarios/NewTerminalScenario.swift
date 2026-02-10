import Foundation

/// E2E scenario: Pair then create a new terminal session
public enum NewTerminalScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "New Terminal",
        tags: ["terminal", "smoke"]
    ) {
        // Reuse the full pairing flow
        FreshPairingScenario.scenario

        // 1. Tap the "+" button on the host header
        TestStep.iosTap(.label("New Session"))
        TestStep.wait(seconds: 2)

        // 2. Tap "New Terminal" in the project picker sheet
        TestStep.iosTap(.labelContains("New Terminal"))
        TestStep.wait(seconds: 3)

        // 3. Verify we navigated to the terminal view
        TestStep.iosScreenshot(label: "04-new-terminal")
    }
}
