import Foundation

/// E2E scenario: Two Mac apps where the viewer is running an old version that the
/// host (current build) does not accept.
///
/// The old viewer should be told "this app is out of date", the current host should
/// be told "viewer is running an older version", and neither side should reconnect.
public enum VersionMismatchOldMacViewerScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Version Mismatch - Old Mac Viewer",
        tags: ["pairing", "version-mismatch", "macos-only"]
    ) {
        // 1. Start relay server
        TestStep.startServer
        TestStep.verifyServerHealth

        // 2. Launch Mac host at the current default version (requires viewer 1.23)
        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.wait(seconds: 3)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "pairingCode")

        // 3. Launch Mac viewer as an old build (version 0.1) with a very low
        //    required-partner-version so the old viewer accepts any host — we only
        //    want the host to reject
        //    the viewer (and the viewer's own "we are too old" check to trigger).
        TestStep.launchMacApp(instance: 1, appVersion: "0.1", minRequiredPartnerVersion: "0.0")
        TestStep.wait(seconds: 3)

        TestStep.macOpenSettings(instance: 1)
        TestStep.macWaitForWindow(titled: "General", timeout: 5, instance: 1)
        TestStep.macSelectSettingsTab("Remote Hosts", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Add Host", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macFocusElement(titled: "Pairing Code", instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "${pairingCode}", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 5)

        // 4. Pair record should exist regardless of version mismatch
        TestStep.verifyServerHasPairings(count: 1)

        // 5. Host sees that the viewer is running an older version and cannot connect.
        //    Rendered via state.statusText which prefixes "Error: ".
        TestStep.macWaitForElement(titled: "running version 0.1", timeout: 20)
        TestStep.macWaitForElement(titled: "cannot connect", timeout: 5)
        TestStep.macScreenshot(label: "host-rejects-old-viewer", compare: false)

        // 6. Old viewer should see the "out of date" update prompt.
        //    Text is rendered in-place (no "Error: " prefix) on RemoteHostsSettingsView.
        TestStep.macWaitForElement(titled: "out of date", timeout: 20, instance: 1)
        TestStep.macWaitForElement(titled: "requires version 1.23", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "old-viewer-sees-update-prompt", compare: false, instance: 1)
    }
}
