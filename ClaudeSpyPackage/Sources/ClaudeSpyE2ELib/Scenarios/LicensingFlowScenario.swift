import Foundation

/// E2E scenario: the hosted-relay licensing gate, end to end against a stub
/// Lemon Squeezy License API (issue #392).
///
/// Three phases against a licensing-enabled relay:
/// 1. **Trial visible** — TRIAL_DAYS=7: the host's first pairing registration
///    auto-starts its trial; the License section shows the countdown.
/// 2. **Blocked** — the relay restarts with TRIAL_DAYS=0 (state wiped, so the
///    next entitlement check auto-starts an instantly-expired trial): pairing
///    is rejected with the typed SUBSCRIPTION_REQUIRED error and the UI points
///    at the License section, which reports "Subscription required".
/// 3. **Activate** — typing the stub-accepted key and clicking Activate flips
///    the section to Active (1 of 3 Macs); pairing then succeeds — proven all
///    the way to a connected iOS viewer, with licensing still enforced
///    (TRIAL_DAYS is still 0, so it's the license doing the unblocking).
///
/// Licensing env is applied by `startServerLicensed` before `configure(app)`
/// runs and cleared on every server stop, so scenarios using plain
/// `startServer` (run after this one in the same process) stay unlicensed.
public enum LicensingFlowScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Licensing Flow",
        tags: ["licensing", "pairing"]
    ) {
        // 1. Clean state; stub LS API + licensing-enabled relay (7-day trial)
        TestStep.terminateMacApp()
        TestStep.startStubLicenseServer
        TestStep.startServerLicensed(trialDays: 7)
        TestStep.verifyServerHealth

        // 2. Launch the Mac host and open Remote Access settings. The
        //    Settings window is not AX-resizable, and the License section is
        //    the last form section (clipped at the default height) — the
        //    license screenshots below over-scroll the form to the bottom
        //    instead, which clamps deterministically.
        TestStep.launchMacApp()
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)

        // 3. Start a pairing attempt: the relay's entitlement check
        //    auto-starts this host's trial. Cancel right away — this phase
        //    only needs the trial record to exist server-side.
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.macWaitForElement(titled: "Enter this code on your iPhone:", timeout: 10)
        TestStep.macClickButton(titled: "Cancel")
        TestStep.macWaitForElement(titled: "Generate Pairing Code", timeout: 5)

        // 4. Reopen Settings so the License section re-fetches its status
        //    (refreshStatus runs from the view's .task) and shows the trial
        //    countdown.
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "Remote Access", timeout: 5)
        TestStep.macWaitForElement(titled: "7 days left", timeout: 10)
        TestStep.macScrollWheel(deltaY: -10, count: 10)
        TestStep.wait(seconds: 0.5)
        // tolerance: 5 matches the VersionMismatch scenarios' Settings-window
        // screenshots — recording (ScreenCaptureKit) shifts rendering ~3.3%
        // on these shots.
        TestStep.macScreenshot(label: "mac-license-trial-countdown", tolerance: 5)

        // 5. Restart the relay with TRIAL_DAYS=0. Relay state is wiped on
        //    stop, so the host's next pairing attempt auto-starts a trial
        //    that is already expired — the "trial over" posture.
        TestStep.stopServer
        TestStep.startServerLicensed(trialDays: 0)
        TestStep.verifyServerHealth

        // 6. Pairing is now blocked with the typed SUBSCRIPTION_REQUIRED
        //    error, surfaced through the pairing error state. Scroll back to
        //    the top first so the Generate button is on screen.
        TestStep.macScrollWheel(deltaY: 10, count: 10)
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.macWaitForElement(titled: "see the License section below", timeout: 10)

        // 7. Reopen Settings: the license status now reports the expired
        //    trial ("Subscription required" in the License section). The
        //    pairing error state persists across the reopen. The status
        //    fetch has no unambiguous AX signal (the pairing error contains
        //    the same "Subscription required" text), so give the localhost
        //    round-trip a moment before the screenshot.
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "Remote Access", timeout: 5)
        TestStep.macWaitForElement(titled: "see the License section below", timeout: 10)
        TestStep.wait(seconds: 1)
        TestStep.macScrollWheel(deltaY: -10, count: 10)
        TestStep.wait(seconds: 0.5)
        // tolerance: 5 — recording (ScreenCaptureKit) shifts rendering ~3.3%
        // on Settings-window shots.
        TestStep.macScreenshot(label: "mac-license-blocked", tolerance: 5)

        // 8. Activate the stub-accepted key. The relay validates it against
        //    the stub LS API (meta store/product ids must match) and the
        //    section flips to Active with the activation usage.
        TestStep.macFocusElement(titled: "License key field")
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: StubLemonSqueezyServer.acceptedLicenseKey)
        // Gate on the field actually holding the key before activating —
        // keystrokes land asynchronously via AppleScript.
        TestStep.macWaitForElementQuery(
            .valueContains(StubLemonSqueezyServer.acceptedLicenseKey),
            timeout: 5
        )
        TestStep.macClickButton(titled: "Activate")
        TestStep.macWaitForElement(titled: "1 of 3 Macs", timeout: 10)
        TestStep.macScrollWheel(deltaY: -10, count: 10)
        TestStep.wait(seconds: 0.5)
        // tolerance: 5 — recording (ScreenCaptureKit) shifts rendering ~3.3%
        // on Settings-window shots.
        TestStep.macScreenshot(label: "mac-license-active", tolerance: 5)

        // 9. Pairing now succeeds — TRIAL_DAYS is still 0, so it's the
        //    license (not a trial) unblocking it. "Try Again" re-runs the
        //    pairing registration from the persisted error state.
        TestStep.macScrollWheel(deltaY: 10, count: 10)
        TestStep.macClickButton(titled: "Try Again")
        TestStep.macWaitForElement(titled: "Enter this code on your iPhone:", timeout: 10)

        // 10. Complete the pairing with a real iOS viewer to prove the whole
        //     loop: register (entitled), pair, and connect both WebSockets
        //     through the licensing-enabled relay.
        TestStep.launchIOSApp()
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 15)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "pairingCode")
        TestStep.iosType(text: "${pairingCode}")
        TestStep.iosWaitForElement(.labelContains("Sessions"), timeout: 15)
        TestStep.iosWaitForElement(.label("Connected"), timeout: 15)
        TestStep.verifyServerHasPairings(count: 1)
        TestStep.waitForHostConnected(timeout: 15)
        TestStep.waitForViewerConnected(timeout: 15)

        // 11. Final steady state on the Mac: viewer row connected, License
        //     section still Active. Same pins as FreshPairing's
        //     "mac-connected" screenshot.
        TestStep.macWaitForElement(titled: "iPhone", timeout: 15)
        TestStep.macWaitForElement(titled: "Viewer connected", timeout: 15)
        TestStep.macWaitForElementQuery(
            .allOf([.role("AXButton"), .label("Disconnect")]),
            timeout: 15
        )
        TestStep.macScrollWheel(deltaY: 10, count: 10)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-license-active-paired", tolerance: 5)
    }
}
