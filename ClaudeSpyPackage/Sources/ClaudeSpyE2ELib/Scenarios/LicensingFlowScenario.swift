import Foundation

/// E2E scenario: the hosted-relay licensing gate, end to end against a stub
/// Lemon Squeezy License API (issue #392).
///
/// The trial clock starts when a viewer COMPLETES pairing (`completePairing`
/// → `startTrialIfNeeded`), not at register/first-touch — and the entitlement
/// check is pure (a device with no trial record is `.preTrial`, allowed). So
/// every phase pivots on a real iOS pairing:
///
/// 1. **Trial visible** — TRIAL_DAYS=7: a real iOS viewer pairs with the
///    host; completing the pairing starts the trial and the License section
///    shows the countdown.
/// 2. **Blocked** — full reset (fresh Mac launch = new host deviceId via the
///    in-memory e2e stores, fresh iOS install, relay restarted with
///    TRIAL_DAYS=0): registration and pairing still succeed (pre-trial is
///    allowed), but completing the pairing starts an instantly-expired
///    trial — the host's WebSocket connect is rejected with
///    SUBSCRIPTION_REQUIRED, the License section reports "Subscription
///    required", iOS surfaces the host's lapsed subscription, and a further
///    Add Viewer registration is blocked pointing at the License section.
/// 3. **Activate** — typing the stub-accepted key and clicking Activate flips
///    the section to Active (1 of 3 Macs); activation auto-resumes the pair
///    the relay blocked (host reconnects through the still-TRIAL_DAYS=0
///    gate — so it's the license doing the unblocking) AND auto-retries the
///    registration the relay blocked: the pairing section flips from the
///    sticky "Subscription required" error straight to a fresh pairing code
///    without clicking Try Again (`retryAfterSubscriptionRestored`).
///
/// Licensing env is applied by `startServerLicensed` before `configure(app)`
/// runs and cleared on every server stop, so scenarios using plain
/// `startServer` (run after this one in the same process) stay unlicensed.
public enum LicensingFlowScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Licensing Flow",
        tags: ["licensing", "pairing"]
    ) {
        // ── Phase 1: trial countdown ────────────────────────────────────

        // 1. Clean state; stub LS API + licensing-enabled relay (7-day trial)
        TestStep.uninstallIOSApp
        TestStep.terminateMacApp()
        TestStep.startStubLicenseServer
        TestStep.startServerLicensed(trialDays: 7)
        TestStep.verifyServerHealth

        // 2. Launch both apps and open Remote Access settings.
        TestStep.launchMacApp()
        TestStep.launchIOSApp()
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 15)
        TestStep.iosClearClipboard
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)

        // 3. Real pairing (same steps as FreshPairing) — completing it is
        //    what starts the host's trial.
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

        // 4. Pairing triggers a license refresh on the Mac
        //    (connectToNewlyPairedViewer → refreshStatus) and the open
        //    Settings view observes it live, so the countdown appears without
        //    a reopen. The Settings window is not AX-resizable and the
        //    License section is the last form section (clipped at the default
        //    height) — over-scroll the form to the bottom instead, which
        //    clamps deterministically.
        TestStep.macWaitForElement(titled: "7 days left", timeout: 10)
        TestStep.macScrollWheel(deltaY: -10, count: 10)
        TestStep.wait(seconds: 0.5)
        // tolerance: 5 matches the VersionMismatch scenarios' Settings-window
        // screenshots — recording (ScreenCaptureKit) shifts rendering ~3.3%
        // on these shots.
        TestStep.macScreenshot(label: "mac-license-trial-countdown", tolerance: 5)

        // ── Phase 2: expired-trial gate ─────────────────────────────────

        // 5. Full reset: fresh iOS install + fresh Mac launch (the e2e
        //    in-memory prefs/secrets die with the process, so the host gets a
        //    new deviceId) + relay restart with TRIAL_DAYS=0 (relay state is
        //    wiped on stop, so no pairs or trials survive).
        TestStep.uninstallIOSApp
        TestStep.terminateMacApp()
        TestStep.stopServer
        TestStep.startServerLicensed(trialDays: 0)
        TestStep.verifyServerHealth
        TestStep.launchMacApp()
        TestStep.launchIOSApp()
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 15)
        TestStep.iosClearClipboard
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)

        // 6. Pair again. Registration is allowed (the gate never starts a
        //    trial) and the pairing completes — but completion starts an
        //    instantly-expired trial, so the host's WebSocket connect is
        //    rejected with SUBSCRIPTION_REQUIRED. The viewer itself is never
        //    gated, so it still connects; the iOS "Connected" pill is skipped
        //    here because the host never comes up.
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "pairingCode2")
        TestStep.iosType(text: "${pairingCode2}")
        TestStep.iosWaitForElement(.labelContains("Sessions"), timeout: 15)
        TestStep.verifyServerHasPairings(count: 1)
        TestStep.waitForViewerConnected(timeout: 15)

        // 7. The expired trial surfaces on both platforms: the Mac's pairing
        //    refresh (plus the rejected connect's onSubscriptionRequired
        //    backstop) flips the License section to "Subscription required",
        //    and the relay's hostSubscriptionInactive notice reaches iOS.
        TestStep.macWaitForElement(titled: "Subscription required", timeout: 15)
        TestStep.iosWaitForElement(.labelContains("subscription expired"), timeout: 15)

        // 8. A new registration is blocked too, pointing at the License
        //    section.
        TestStep.macClickButton(titled: "Add Viewer")
        TestStep.macWaitForElement(titled: "see the License section below", timeout: 10)
        TestStep.macScrollWheel(deltaY: -10, count: 10)
        TestStep.wait(seconds: 0.5)
        // tolerance: 5 — recording (ScreenCaptureKit) shifts rendering ~3.3%
        // on Settings-window shots.
        TestStep.macScreenshot(label: "mac-license-blocked", tolerance: 5)

        // ── Phase 3: license activation unblocks ────────────────────────

        // 9. Activate the stub-accepted key. The relay validates it against
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

        // 10. Activation auto-resumes the pair the relay blocked
        //     (onActivationSuccess → enableReconnectAndRetryAll): the host
        //     reconnects through the still-TRIAL_DAYS=0 gate — the license,
        //     not a trial, is doing the unblocking. It ALSO auto-retries the
        //     registration the relay blocked (retryAfterSubscriptionRestored):
        //     the pairing section flips from the sticky "Subscription
        //     required" error straight to a fresh code, no Try Again click.
        //     iOS's connection goes fully green once the host is back.
        TestStep.macWaitForElement(titled: "Enter this code on your iPhone:", timeout: 10)
        TestStep.waitForHostConnected(timeout: 15)
        TestStep.waitForViewerConnected(timeout: 15)
        TestStep.iosWaitForElement(.label("Connected"), timeout: 15)
        TestStep.macWaitForElement(titled: "Viewer connected", timeout: 15)
        TestStep.macWaitForElementQuery(
            .allOf([.role("AXButton"), .label("Disconnect")]),
            timeout: 15
        )
        TestStep.macScrollWheel(deltaY: -10, count: 10)
        TestStep.wait(seconds: 0.5)
        // tolerance: 5 — recording (ScreenCaptureKit) shifts rendering ~3.3%
        // on Settings-window shots, and this shot includes the auto-opened
        // pairing code + ticking expiry countdown (random per run, same as
        // FreshPairing's code-generated shot).
        TestStep.macScreenshot(label: "mac-license-active", tolerance: 5)

        // 11. Cancel the auto-opened code flow; the section settles back to
        //     the paired list with Add Viewer available.
        TestStep.macScrollWheel(deltaY: 10, count: 10)
        TestStep.macClickButton(titled: "Cancel")
        TestStep.macWaitForElement(titled: "Add Viewer", timeout: 5)

        // 12. Final steady state on the Mac: viewer row connected, License
        //     section still Active. Same pins as FreshPairing's
        //     "mac-connected" screenshot.
        TestStep.macWaitForElement(titled: "iPhone", timeout: 15)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-license-active-paired", tolerance: 5)
    }
}
