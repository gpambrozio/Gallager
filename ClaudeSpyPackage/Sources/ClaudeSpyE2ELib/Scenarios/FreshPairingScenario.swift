import Foundation

/// First E2E scenario: Fresh device pairing flow
public enum FreshPairingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Fresh Pairing",
        tags: ["pairing", "smoke"]
    ) {
        // 1. Uninstall previous app to ensure fresh state
        TestStep.uninstallIOSApp

        // 2. Start server on localhost
        TestStep.startServer(port: 8_765)
        TestStep.verifyServerHealth

        // 3. Launch iOS in simulator
        TestStep.launchIOSApp(arguments: ["--e2e-test", "--server-url", "ws://127.0.0.1:8765"])
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 15)
        TestStep.iosScreenshot(label: "01-ios-pairing-view")

        // 4. Launch macOS app
        TestStep.launchMacApp(arguments: ["--e2e-test", "--server-url", "ws://127.0.0.1:8765"])
        TestStep.wait(seconds: 3)

        // 5. Generate pairing code on macOS
        TestStep.macOpenSettings
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.wait(seconds: 3)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "pairingCode")
        TestStep.macScreenshot(label: "02-mac-code-generated")

        // 6. Enter code on iOS
        TestStep.wait(seconds: 1)
        TestStep.iosType(text: "${pairingCode}")
        TestStep.wait(seconds: 5)

        // 7. Verify iOS transitioned to main view
        TestStep.iosWaitForElement(.labelContains("Sessions"), timeout: 10)
        TestStep.iosScreenshot(label: "03-ios-paired")

        // 8. Verify server state
        TestStep.verifyServerHasPairings(count: 1)
    }
}
