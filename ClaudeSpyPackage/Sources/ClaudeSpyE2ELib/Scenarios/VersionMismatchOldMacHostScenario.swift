import Foundation

/// E2E scenario: Two Mac apps where the host is running an old version that the
/// viewer (current build) does not accept.
///
/// The old host should be told "this app is out of date", the current viewer should
/// be told "host is running an older version", and neither side should try to reconnect.
public enum VersionMismatchOldMacHostScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Version Mismatch - Old Mac Host",
        tags: ["pairing", "version-mismatch", "macos-only"]
    ) {
        // 1. Start relay server
        TestStep.startServer
        TestStep.verifyServerHealth

        // 2. Launch Mac host as an old build (version 0.1) with a very low
        //    required-partner-version so the old host accepts any viewer — we only
        //    want the viewer to reject
        //    the host (and the host's own "we are too old" check to trigger).
        TestStep.launchMacApp(instance: 0, appVersion: "0.1", minRequiredPartnerVersion: "0.0")
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

        // 3. Launch Mac viewer at the current default version (requires host 1.23)
        TestStep.launchMacApp(instance: 1)
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

        // 5. Viewer should see host is running an older version and cannot connect.
        //    Text is rendered in-place (no "Error: " prefix) on RemoteHostsSettingsView.
        TestStep.macWaitForElement(titled: "running version 0.1", timeout: 20, instance: 1)
        TestStep.macWaitForElement(titled: "cannot connect", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-rejects-old-host", instance: 1)

        // 6. Host sees "This Mac app is out of date" once the viewer's peerHello
        //    arrives peer-to-peer and carries the viewer's minRequiredHostVersion.
        TestStep.macWaitForElement(titled: "out of date", timeout: 20)
        TestStep.macWaitForElement(titled: "requires version 1.23", timeout: 5)
        TestStep.macScreenshot(label: "old-host-sees-update-prompt")
    }
}
