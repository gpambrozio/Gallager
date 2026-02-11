import Foundation

/// E2E scenario: Disconnect macOS, unpair from iOS, reconnect macOS gets INVALID_PAIR
public enum DisconnectMacOSUnpairIOSScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Disconnect macOS, Unpair iOS",
        tags: ["unpair", "reconnect"]
    ) {
        // 1. Establish a fresh pairing
        FreshPairingScenario.scenario

        // 2. Server: disconnect the host (macOS) WebSocket
        TestStep.serverDisconnectDevice(.host)
        TestStep.wait(seconds: 1)

        // 3. iOS: navigate to Manage Hosts and unpair.
        // The "Delete" action directly removes the pairing (bypasses confirmation
        // dialog, which isn't accessible via HTTP on iOS 26).
        TestStep.iosTap(.labelContains("Settings"))
        TestStep.wait(seconds: 0.5)
        TestStep.iosTap(.labelContains("Paired Hosts"))
        TestStep.wait(seconds: 0.5)
        TestStep.iosSwipeLeft(.identifier("host-row"))
        TestStep.wait(seconds: 2)

        // 4. Verify server has 0 pairings
        TestStep.waitForNoPairings(timeout: 15)
        TestStep.verifyServerHasPairings(count: 0)

        // 5. Wait for macOS to auto-reconnect and receive INVALID_PAIR → removes pairing
        TestStep.wait(seconds: 15)

        // 6. macOS screenshot to verify cleanup
        TestStep.macScreenshot(label: "disconnect-macos-unpair-ios-done")
    }
}
