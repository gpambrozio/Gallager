import Foundation

/// E2E scenario: Unpair from iOS and verify macOS cleans up
public enum UnpairFromIOSScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Unpair from iOS",
        tags: ["unpair"]
    ) {
        // 1. Establish a fresh pairing
        FreshPairingScenario.scenario

        // 2. Navigate to Manage Hosts on iOS
        TestStep.iosLogUI
        TestStep.iosTap(.labelContains("Settings"))
        TestStep.wait(seconds: 0.5)
        TestStep.iosTap(.labelContains("Paired Hosts"))
        TestStep.wait(seconds: 0.5)

        // 3. Delete the host via accessibility custom action.
        // The "Delete" action directly removes the pairing (bypasses confirmation
        // dialog, which isn't accessible via HTTP on iOS 26).
        TestStep.iosSwipeLeft(.identifier("host-row"))
        TestStep.wait(seconds: 2)

        // 4. Verify server has 0 pairings
        TestStep.waitForNoPairings(timeout: 15)
        TestStep.verifyServerHasPairings(count: 0)

        // 5. Verify iOS returns to pairing view
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 10)
        TestStep.iosScreenshot(label: "unpair-ios-done")
    }
}
