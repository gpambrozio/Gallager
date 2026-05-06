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

        // 3. Launch macOS app (must be fresh launch for --e2e-test args to take effect)
        TestStep.launchMacApp()

        // 4. Launch iOS in simulator
        TestStep.launchIOSApp()
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-pairing-view")

        // 5. Generate pairing code on macOS
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "pairingCode")
        TestStep.macScreenshot(label: "mac-code-generated", tolerance: 5)

        // 6. Enter code on iOS
        TestStep.iosType(text: "${pairingCode}")

        // 7. Verify iOS transitioned to main view and connected
        TestStep.iosWaitForElement(.labelContains("Sessions"), timeout: 15)
        TestStep.iosWaitForElement(.label("Connected"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-paired")

        // 8. Verify server state
        TestStep.verifyServerHasPairings(count: 1)

        // 9. Wait for both host and viewer to connect to relay server
        TestStep.waitForHostConnected(timeout: 15)
        TestStep.waitForViewerConnected(timeout: 15)
        TestStep.macWaitForElement(titled: "Viewer connected", timeout: 15)
        TestStep.macScreenshot(label: "mac-connected", tolerance: 5)

        // 10. Set a custom device name on iOS and verify it propagates to the
        //     macOS "Paired Viewers" cell. Before this issue, the cell was
        //     hardcoded to "Viewer" — we now expect the name the iOS user set.
        TestStep.iosTap(.label("Settings"))
        TestStep.iosWaitForElement(.label("Device Name"), timeout: 5)
        TestStep.iosTap(.identifier("device-name-field"))
        TestStep.wait(seconds: 0.5)
        TestStep.iosType(text: "E2E Test iPhone\n")
        TestStep.wait(seconds: 0.5)

        // The iOS commit triggers a disconnect+reconnect that re-registers
        // the viewer with the new name. Allow time for the round-trip.
        TestStep.macWaitForElement(titled: "E2E Test iPhone", timeout: 20)
        TestStep.macScreenshot(label: "mac-viewer-renamed", tolerance: 5)

        // Wait for the viewer to reconnect after the rename so subsequent
        // scenarios that rely on a connected viewer don't race the recovery.
        TestStep.waitForViewerConnected(timeout: 15)

        // Close the iOS Settings sheet so downstream scenarios that build on
        // FreshPairingScenario start from the same Sessions-list state as before.
        TestStep.iosTap(.label("Done"))
        TestStep.iosWaitForElementToDisappear(.label("Device Name"), timeout: 5)
    }
}
