import Foundation

/// First E2E scenario: Fresh device pairing flow
public enum FreshPairingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Fresh Pairing",
        tags: ["pairing", "smoke"]
    ) {
        // 1. Clean up any previous state
        TestStep.uninstallIOSApp
        TestStep.terminateMacApp()

        // 2. Start server on localhost
        TestStep.startServer
        TestStep.verifyServerHealth

        // 3. Launch iOS in simulator
        TestStep.launchIOSApp
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-pairing-view")

        // 4. Launch macOS app (must be fresh launch for --e2e-test args to take effect)
        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        // 5. Generate pairing code on macOS
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.wait(seconds: 3)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "pairingCode")
        TestStep.macScreenshot(label: "mac-code-generated", tolerance: 5)

        // 6. Enter code on iOS
        TestStep.wait(seconds: 1)
        TestStep.iosType(text: "${pairingCode}")
        TestStep.wait(seconds: 5)

        // 7. Verify iOS transitioned to main view
        TestStep.iosWaitForElement(.labelContains("Sessions"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-paired")

        // 8. Verify server state
        TestStep.verifyServerHasPairings(count: 1)

        // 9. Wait for both host and viewer to connect to relay server
        TestStep.waitForHostConnected(timeout: 15)
        TestStep.waitForViewerConnected(timeout: 15)
        TestStep.macScreenshot(label: "mac-connected"), tolerance: 5)

        // 10. Verify macOS shows "Connected" on settings page (not "Waiting for viewer")
        TestStep.macWaitForElement(titled: "Connected", timeout: 15)
    }
}
