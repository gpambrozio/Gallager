import Foundation

/// E2E scenario: the relay's optional server-side minimum-client-version gate
/// (issue #659). Unlike the peer-to-peer version handshake, this is enforced by
/// the relay itself against the pre-E2EE `clientVersion` query parameter.
///
/// The relay boots with `MIN_CLIENT_VERSION=2.1`. A current-build Mac host
/// generates a pairing code; a Mac viewer launched as an old build (0.1) pairs
/// with it. Pairing is HTTP and ungated, so the pair record still forms — but
/// the relay refuses the old viewer's WebSocket connect with a `CLIENT_TOO_OLD`
/// error before any E2EE/peerHello, so the viewer surfaces the server's
/// "please update" message (proving the rejection is the *server gate*, not the
/// peer-to-peer mismatch), and stops reconnecting.
public enum ServerMinClientVersionGateScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Server Min Client Version Gate",
        tags: ["pairing", "version-gate", "macos-only"]
    ) {
        // 1. Relay with the minimum-client-version gate enabled (min 2.1).
        TestStep.startServerWithMinClientVersion(minVersion: "2.1")
        TestStep.verifyServerHealth

        // 2. Host on the current build (accepted by the gate) generates a code.
        TestStep.launchMacApp(instance: 0)
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

        // 3. Viewer launched as an OLD build (0.1), below the relay's 2.1 minimum.
        TestStep.launchMacApp(instance: 1, appVersion: "0.1")
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

        // 4. Pairing itself is HTTP and ungated, so the pair record still forms.
        TestStep.verifyServerHasPairings(count: 1)

        // 5. The relay refuses the old viewer's WebSocket connect with
        //    CLIENT_TOO_OLD, so the host row shows the server's "please update"
        //    message. The wording ("no longer supported by the server") proves it
        //    is the server gate, not the peer-to-peer mismatch (which never runs —
        //    the relay rejects before E2EE/peerHello).
        TestStep.macWaitForElement(titled: "no longer supported by the server", timeout: 20, instance: 1)
        TestStep.macWaitForElement(titled: "Please update", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-rejected-by-server-gate", tolerance: 5, instance: 1)
    }
}
