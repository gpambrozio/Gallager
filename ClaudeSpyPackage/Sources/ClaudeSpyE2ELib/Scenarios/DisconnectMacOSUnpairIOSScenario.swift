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
        TestStep.macScreenshot(label: "06.1-mac-after-disconnect")

        // 3. iOS: navigate to Manage Hosts and unpair
        TestStep.iosTap(.labelContains("Settings"))
        TestStep.wait(seconds: 0.5)
        TestStep.iosTap(.labelContains("Paired Hosts"))
        TestStep.wait(seconds: 0.5)
        TestStep.iosScreenshot(label: "06.2-ios-paired-hosts")

        // 4. Swipe left to reveal delete button, tap it
        TestStep.iosSwipeLeft(.identifier("host-row"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Delete"))
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "06.3-ios-confirm-dialog")

        // 5. Tap the confirmation dialog button (use Button role to avoid matching dialog title)
        TestStep.iosTap(.roleAndLabelContains(role: "Button", label: "Remove"))
        TestStep.wait(seconds: 2)

        // 6. Verify server has 0 pairings
        TestStep.waitForNoPairings(timeout: 15)
        TestStep.verifyServerHasPairings(count: 0)

        // 7. Wait for macOS to auto-reconnect and receive INVALID_PAIR → removes pairing
        TestStep.wait(seconds: 15)

        // 8. Verify both sides cleaned up
        TestStep.macScreenshot(label: "06.4-mac-invalid-pair-cleanup")
    }
}
