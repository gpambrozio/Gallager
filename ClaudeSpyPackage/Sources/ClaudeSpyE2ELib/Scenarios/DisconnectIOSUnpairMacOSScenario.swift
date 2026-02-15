import Foundation

/// E2E scenario: Disconnect iOS, unpair from macOS, reconnect iOS gets INVALID_PAIR
public enum DisconnectIOSUnpairMacOSScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Disconnect iOS, Unpair macOS",
        tags: ["unpair", "reconnect"]
    ) {
        // 1. Establish a fresh pairing
        FreshPairingScenario.scenario

        // 2. Server: disconnect the viewer (iOS) WebSocket
        TestStep.serverDisconnectDevice(.viewer)
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-after-disconnect")

        // 3. macOS: trigger unpair via test HTTP endpoint
        // (SwiftUI Menu creates native NSMenu popups invisible to the accessibility tree)
        TestStep.macUnpair
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-after-unpair")

        // 4. Verify server has 0 pairings
        TestStep.waitForNoPairings(timeout: 15)
        TestStep.verifyServerHasPairings(count: 0)

        // 5. Wait for iOS to auto-reconnect and receive INVALID_PAIR → removes pairing
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 30)
        TestStep.iosScreenshot(label: "ios-invalid-pair-cleanup")
    }
}
