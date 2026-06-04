import Foundation

/// E2E scenario: Mac host is running an older app version than the iOS viewer requires.
///
/// The old Mac host should be told "this app is out of date", the current iOS viewer
/// should be told "host is running version 0.1 and cannot connect", and neither side
/// should try to reconnect.
public enum VersionMismatchOldMacHostIOSViewerScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Version Mismatch - Old Mac Host with iOS Viewer",
        tags: ["pairing", "version-mismatch"]
    ) {
        // 1. Clean state
        TestStep.uninstallIOSApp
        TestStep.terminateMacApp()

        // 2. Start relay server
        TestStep.startServer
        TestStep.verifyServerHealth

        // 3. Launch Mac host as an old build (version 0.1) with a very low
        //    required-partner-version so the old host accepts any viewer — we only
        //    want the viewer to reject the host (and the host's own "we are too old"
        //    check to trigger).
        TestStep.launchMacApp(appVersion: "0.1", minRequiredPartnerVersion: "0.0")

        // 4. Launch iOS viewer at the current default version (its default
        //    minimum requires an up-to-date host).
        TestStep.launchIOSApp()
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
        // iOS transitions from PairingView to MainView once pairing completes,
        // regardless of the version mismatch that fires during peerHello.
        TestStep.iosWaitForElement(.labelContains("Sessions"), timeout: 15)

        // 7. Server accepted the pair record (versions are enforced in peerHello, not pairing)
        TestStep.verifyServerHasPairings(count: 1)

        // 8. Mac host should see "This Mac app is out of date" once the iOS viewer's
        //    peerHello arrives peer-to-peer and carries the viewer's minRequiredHostVersion.
        //    tolerance: 5 matches the FreshPairing scenario's Settings-window screenshots —
        //    these captures are slightly non-deterministic across runs when the iOS
        //    simulator is in play.
        TestStep.macWaitForElement(titled: "out of date", timeout: 20)
        // swiftlint:disable:next custom_no_number_decimals
        TestStep.macWaitForElement(titled: "requires version 2.0", timeout: 5)
        TestStep.macScreenshot(label: "mac-host-sees-update-prompt", tolerance: 5)

        // 9. iOS lands on the Sessions tab after pairing. The host section there
        //    should surface the HostVersionMismatchRow callout naming the host
        //    and its outdated version, without any Settings drill-in.
        TestStep.iosWaitForElement(.identifier("host-version-mismatch-row"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("needs updating"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("running version 0.1"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-viewer-rejects-old-mac-host")

        // 10. Simulate the user "updating" the Mac host: clear its version
        //     overrides. The Mac host's notification observer brings the relay
        //     session back online so the iOS Retry below can find a peer.
        TestStep.macSetAppVersion(appVersion: nil, minRequiredPartnerVersion: nil)
        TestStep.wait(seconds: 2)

        // 11. Drive the new Retry affordance on iOS. This direction is
        //     `.partnerTooOld` (the Mac host is the outdated side), so the row
        //     title is "MacBook needs updating"; tapping it opens the
        //     confirmation dialog.
        TestStep.iosTap(.identifier("host-version-mismatch-row"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Retry"))

        // 12. Both sides should reach a connected state — the Sessions-tab
        //     callout disappears and the host section collapses to "No active
        //     sessions"; Mac Remote Access shows "Connected".
        TestStep.iosWaitForElementToDisappear(.identifier("host-version-mismatch-row"), timeout: 20)
        TestStep.iosWaitForElement(.labelContains("No active sessions"), timeout: 20)
        TestStep.macWaitForElementToDisappear(titled: "out of date", timeout: 20)
        TestStep.macWaitForElement(titled: "Viewer connected", timeout: 20)
        TestStep.iosScreenshot(label: "ios-after-host-upgrade")
        TestStep.macScreenshot(label: "mac-host-after-upgrade", tolerance: 5)
    }
}
