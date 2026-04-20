import Foundation

/// E2E scenario: iOS viewer is running an older app version than the Mac host requires.
///
/// Both sides should surface a version-mismatch error and stop reconnecting. Pairing
/// itself still succeeds (the pair record is created) — version enforcement happens
/// peer-to-peer in the encrypted `peerHello` exchange once both sides are online;
/// the relay server never sees or touches version info.
public enum VersionMismatchOldIOSViewerScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Version Mismatch - Old iOS Viewer",
        tags: ["pairing", "version-mismatch"]
    ) {
        // 1. Clean state
        TestStep.uninstallIOSApp
        TestStep.terminateMacApp()

        // 2. Start relay server
        TestStep.startServer
        TestStep.verifyServerHealth

        // 3. Launch Mac host with default version (1.23, requires viewer 1.23)
        TestStep.launchMacApp()

        // 4. Launch iOS viewer pretending to be an old build (version 0.1).
        //    The required-partner-version is set very low so the viewer itself
        //    would accept any host — we only want the host to reject the viewer
        //    here, plus the reciprocal "we are too old" detection on iOS.
        TestStep.launchIOSApp(appVersion: "0.1", minRequiredPartnerVersion: "0.0")
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 15)

        // 5. Generate pairing code on macOS and copy it
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "pairingCode")

        // 6. Enter the code on iOS — the pairing REST call succeeds, but the
        //    peer-to-peer `peerHello` exchange that follows will surface the mismatch.
        TestStep.iosType(text: "${pairingCode}")
        TestStep.wait(seconds: 3)

        // 7. Server accepted the pair record (versions are enforced in peerHello, not pairing)
        TestStep.verifyServerHasPairings(count: 1)

        // 8. Mac host should surface an error referencing the old viewer version.
        //    The status text goes through `state.statusText` which prefixes "Error: ".
        TestStep.macWaitForElement(titled: "running version 0.1", timeout: 20)
        TestStep.macWaitForElement(titled: "cannot connect", timeout: 5)
        // tolerance: 5 matches the FreshPairing scenario's Settings-window
        // screenshots — these captures are slightly non-deterministic across runs
        // when the iOS simulator is in play.
        TestStep.macScreenshot(label: "mac-host-rejects-old-ios-viewer", tolerance: 5)

        // 9. The old side (iOS) should never reach the connected state.
        //    Assert that the iOS status line explicitly reports "Disconnected" so a
        //    regression where the viewer reaches "Connected" is caught by the test
        //    itself, not just visible in the screenshot.
        TestStep.wait(seconds: 5)
        TestStep.iosWaitForElement(.labelContains("Disconnected"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-version-mismatch-state")
    }
}
