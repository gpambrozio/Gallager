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
        TestStep.macScreenshot(label: "host-rejects-old-viewer", tolerance: 5)

        // 6. Old viewer should see the "out of date" update prompt.
        //    Text is rendered in-place (no "Error: " prefix) on RemoteHostsSettingsView.
        TestStep.macWaitForElement(titled: "out of date", timeout: 20, instance: 1)
        TestStep.macWaitForElement(titled: "requires version 1.23", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "old-viewer-sees-update-prompt", tolerance: 5, instance: 1)

        // 7. Close the viewer's Settings window and surface its main Panes
        //    window so we can verify the dedicated HostVersionMismatchRow
        //    surfaces in the sidebar. Because this direction is ".weAreTooOld",
        //    the callout title should read "Update this app".
        //    `Shortcut.openPanesWindow` positions and resizes the window so
        //    sidebar screenshots stay deterministic across runs.
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        TestStep.wait(seconds: 0.5)
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macWaitForElementQuery(
            .identifier("host-version-mismatch-row"), timeout: 10, instance: 1
        )
        TestStep.macWaitForElement(titled: "Update this app", timeout: 5, instance: 1)
        TestStep.macWaitForElement(titled: "requires version 1.23", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-sidebar-mismatch", tolerance: 5, instance: 1)

        // 8. Simulate the user "updating" the viewer: clear its version
        //    overrides. Also nudge instance 0 — its version isn't overridden but
        //    `macSetAppVersion` triggers the host-side notification observer,
        //    which brings the host's relay session back online so the viewer's
        //    Retry can find a peer to handshake with.
        TestStep.macSetAppVersion(
            appVersion: nil, minRequiredPartnerVersion: nil, instance: 1
        )
        TestStep.macSetAppVersion(appVersion: nil, minRequiredPartnerVersion: nil)
        TestStep.wait(seconds: 2)

        // 9. Drive the new Retry affordance on the viewer side. This direction
        //    is `.weAreTooOld`, so the row title is "Update this app".
        TestStep.macClickButton(titled: "Update this app", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Retry", instance: 1)

        // 10. The sidebar mismatch row disappears on the viewer once the new
        //     peerHello validates. With no tmux sessions running, the reachable
        //     host collapses to the "No active sessions" caption. The host
        //     proves recovery via its Remote Access "1 viewer connected"
        //     subtitle, which only appears once the relay has actually
        //     re-registered the viewer's session — waiting on the bare
        //     "Connected" label is too eager and produces flaky screenshots.
        TestStep.macWaitForElementQueryToDisappear(
            .identifier("host-version-mismatch-row"), timeout: 20, instance: 1
        )
        TestStep.macWaitForElement(titled: "No active sessions", timeout: 20, instance: 1)
        TestStep.macWaitForElementToDisappear(titled: "running version 0.1", timeout: 20)
        TestStep.macWaitForElement(titled: "1 viewer connected", timeout: 20)
        TestStep.macScreenshot(label: "host-after-viewer-upgrade", tolerance: 5)
        TestStep.macScreenshot(label: "viewer-sidebar-reconnected", tolerance: 5, instance: 1)
    }
}
