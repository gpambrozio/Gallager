import Foundation

/// E2E scenario: Unpair from iOS and verify macOS cleans up
public enum UnpairFromIOSScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Unpair from iOS",
        tags: ["unpair"]
    ) {
        // 1. Establish a fresh pairing
        FreshPairingScenario.scenario

        // 2. Navigate to Manage Hosts on iOS — open Settings sheet then push Paired Hosts
        TestStep.iosTap(.label("Settings"))
        // Wait for the sheet itself before looking inside it; otherwise a
        // failure here reports "Paired Hosts not found" which hides the
        // real problem (sheet never presented).
        TestStep.iosWaitForElement(.label("Settings"), timeout: 3)
        TestStep.iosWaitForElement(.labelContains("Paired Hosts"), timeout: 5)
        // The first synthesized tap on a NavigationLink inside a freshly
        // presented sheet doesn't reliably activate it on iOS — the second
        // tap then pushes ManageHostsView onto the sheet's NavigationStack.
        TestStep.iosTap(.labelContains("Paired Hosts"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Paired Hosts"))
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-paired-hosts")

        // 3. Swipe left to reveal delete button, tap it
        TestStep.iosSwipeLeft(.identifier("host-row"))
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-swipe-delete")
        TestStep.iosTap(.label("Delete"))
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-confirm-dialog")

        // 4. Tap the confirmation dialog button (use Button role to avoid matching dialog title)
        TestStep.iosTap(.roleAndLabelContains(role: "Button", label: "Remove"))
        TestStep.wait(seconds: 2)

        // 5. Verify server has 0 pairings
        TestStep.waitForNoPairings(timeout: 15)
        TestStep.verifyServerHasPairings(count: 0)

        // 6. Verify iOS returns to pairing view
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-back-to-pairing")
    }
}
