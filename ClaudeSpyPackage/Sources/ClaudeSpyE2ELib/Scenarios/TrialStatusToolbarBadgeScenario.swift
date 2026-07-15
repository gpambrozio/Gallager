import Foundation

/// E2E scenario: the toolbar trial-status badge + its buy/activate popover
/// (issue #392, Task 5).
///
/// Unlike `LicensingFlowScenario` — which proves the *enforcement* path
/// against a licensed relay + stub Lemon Squeezy API — this scenario proves
/// the *badge UI* in isolation. `--e2e-license-state` overrides
/// `LicensingClient` so `LicenseManager.status` is deterministic regardless
/// of the relay's own licensing configuration; the relay here is a plain
/// `startServer`, same as `FreshPairingScenario`.
public enum TrialStatusToolbarBadgeScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Trial Status Toolbar Badge",
        tags: ["licensing", "pairing"]
    ) {
        // 1. Clean state; plain (unlicensed) relay.
        TestStep.uninstallIOSApp
        TestStep.terminateMacApp()
        TestStep.startServer
        TestStep.verifyServerHealth

        // 2. Launch the host with a deterministic 5-day trial and bring up the
        //    Panes window (the badge lives in MainView's toolbar, not
        //    Settings) — just enough to get the toolbar into the AX tree, not
        //    the full `Shortcut.openPanesWindow()` sizing dance, which is
        //    reserved for the one window we actually screenshot below (a
        //    second move/resize on an already-open window is flaky — it can
        //    catch the window mid-(re)activation and shrink the captured
        //    frame). The 30-minute license-monitoring loop
        //    (AppCoordinator.startLicenseMonitoring) calls refreshStatus()
        //    almost immediately, so LicenseManager.status is already `.trial`
        //    well before any viewer pairs — proving it's the toolbar item's
        //    `settings.isPaired` gate (not an unpopulated status) that keeps
        //    the badge hidden here, with the toolbar itself confirmed
        //    on-screen (not just absent because nothing rendered yet).
        TestStep.launchMacApp(licenseState: "trial")
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Gallager", timeout: 5)
        TestStep.macWaitForElementQueryToDisappear(.identifier("trial-status-badge"), timeout: 5)

        // 3. Standard pairing flow (same steps as `FreshPairingScenario`):
        //    generate a code on the Mac, redeem it on iOS. Completing pairing
        //    calls `connectToNewlyPairedViewer` → `licenseManager.refreshStatus()`
        //    (Task 4), which flips `settings.isPaired` — the badge's gate.
        TestStep.launchIOSApp()
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 15)
        TestStep.iosClearClipboard

        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "pairingCode")

        TestStep.iosType(text: "${pairingCode}")
        TestStep.iosWaitForElement(.labelContains("Sessions"), timeout: 15)
        TestStep.iosWaitForElement(.label("Connected"), timeout: 15)
        TestStep.verifyServerHasPairings(count: 1)
        TestStep.waitForHostConnected(timeout: 15)
        TestStep.waitForViewerConnected(timeout: 15)
        TestStep.macWaitForElement(titled: "Viewer connected", timeout: 15)
        TestStep.macCloseWindow(titled: "Remote Access")

        // 4. The badge lives in the Panes window's toolbar (MainView), not
        //    Settings — bring it forward so the AX tree and the screenshot
        //    both capture it.
        Shortcut.openPanesWindow()

        // 5. The toolbar badge now shows the deterministic 5-day countdown.
        TestStep.macWaitForElementQuery(.identifier("trial-status-badge"), timeout: 15)
        TestStep.macWaitForElement(titled: "5 days left", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-trial-badge-toolbar", tolerance: 5)

        // 6. Clicking it opens the Buy / license-key / Activate popover.
        TestStep.macCGClickElement(query: .identifier("trial-status-badge"))
        TestStep.macWaitForElementQuery(.identifier("trial-popover-buy"), timeout: 5)
        TestStep.macWaitForElementQuery(.identifier("trial-popover-license-key"), timeout: 5)
        TestStep.macWaitForElementQuery(.identifier("trial-popover-activate"), timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-trial-badge-popover", tolerance: 5)
    }
}
