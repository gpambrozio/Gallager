import Foundation

/// E2E scenario: Disconnect macOS, unpair from iOS, reconnect macOS gets INVALID_PAIR
public enum DisconnectMacOSUnpairIOSScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Disconnect macOS, Unpair iOS",
        tags: ["unpair", "reconnect"]
    ) {
        // 1. Establish a fresh pairing
        FreshPairingScenario.scenario

        // 2. Server: block the host (macOS) from reconnecting and disconnect it.
        //    This prevents auto-reconnection so the unpair truly happens while macOS is offline.
        TestStep.serverBlockDevice(.host)
        TestStep.wait(seconds: 3)
        TestStep.macWaitForElementToDisappear(titled: "Connected")
        TestStep.macScreenshot(label: "mac-after-disconnect")

        // 3. iOS: navigate to Manage Hosts and unpair via Settings sheet
        TestStep.iosTap(.label("Settings"))
        TestStep.iosWaitForElement(.labelContains("Paired Hosts"), timeout: 5)
        TestStep.iosTap(.labelContains("Paired Hosts"))
        TestStep.wait(seconds: 0.5)
        TestStep.iosScreenshot(label: "ios-paired-hosts")

        // 4. Swipe left to reveal delete button, tap it
        TestStep.iosSwipeLeft(.identifier("host-row"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Delete"))
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-confirm-dialog")

        // 5. Tap the confirmation dialog button (use Button role to avoid matching dialog title)
        TestStep.iosTap(.roleAndLabelContains(role: "Button", label: "Remove"))
        TestStep.wait(seconds: 2)

        // 6. Verify server has 0 pairings (while macOS is still blocked)
        TestStep.waitForNoPairings(timeout: 15)
        TestStep.verifyServerHasPairings(count: 0)

        // 7. Unblock macOS so it can reconnect. The server will reject it with INVALID_PAIR
        //    since the pairing was removed. macOS should detect the error and clean up.
        TestStep.serverUnblockDevice(.host)
        TestStep.wait(seconds: 15)
        TestStep.macWaitForElement(titled: "Generate Pairing Code")

        // 8. Verify macOS cleaned up
        TestStep.macScreenshot(label: "mac-invalid-pair-cleanup")
    }
}
