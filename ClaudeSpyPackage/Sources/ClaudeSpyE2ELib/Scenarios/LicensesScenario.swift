import Foundation

/// E2E test for the in-app third-party license acknowledgements (issue #683)
/// on both macOS (Settings → About "Licenses" section) and iOS (Settings →
/// "Licenses" pushed list).
///
/// Both platforms render the same shared `ThirdPartyLicense.all` data through
/// the shared `LicenseRow`, so a regression that drops the section, breaks the
/// shared view, or unlinks a dependency shows up as a missing element (the
/// `waitForElement` assertions) or a screenshot diff.
///
/// Pairing is required only to reach the iOS Settings sheet (behind the
/// Sessions toolbar, visible only after pairing). The macOS portion
/// piggy-backs on the same paired setup — we just switch the Settings tab from
/// "Remote Access" (left over from pairing) to "About".
///
/// Element matching uses substring queries throughout: the macOS driver's
/// `titled:` is `anyTextMatches` (contains), and on iOS each row is a `Link`
/// whose children combine into a single "<name>, <license>" label, so
/// `.labelContains` matches a project name regardless of the trailing license.
public enum LicensesScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Licenses",
        tags: ["about", "settings", "licenses"]
    ) {
        FreshPairingScenario.scenario

        // ── macOS: Settings → About "Licenses" section ─────────────

        TestStep.macSelectSettingsTab("About")

        // The Licenses section sits below the (tall) "Why Gallager" and
        // "Links" sections, so its rows start off-screen. They're still in
        // the AX tree, so assert the header + first/last rows exist before
        // scrolling them into view for the baseline.
        TestStep.macWaitForElement(titled: "Licenses", timeout: 5)
        TestStep.macWaitForElement(titled: "SwiftTerm", timeout: 5)
        TestStep.macWaitForElement(titled: "Unicode CLDR emoji data", timeout: 5)
        TestStep.wait(seconds: 0.5)

        // Scroll the About form to the bottom (deltaY clamps there, so the
        // frame is deterministic) so the tail of the license list + footer
        // fill the screenshot.
        TestStep.macScrollWheel(deltaY: -10, count: 12)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-about-licenses")

        // ── iOS: Settings → "Licenses" pushed list ─────────────────

        // Open the Settings sheet from the Sessions toolbar.
        TestStep.iosTap(.label("Settings"))
        TestStep.iosWaitForElement(.label("Device Name"), timeout: 5)
        TestStep.wait(seconds: 0.5)

        // "Licenses" is the last row of a long settings List, so swipe up to
        // scroll it into the hittable area — the simulator taps the element's
        // resolved center coordinate and does not auto-scroll to off-screen
        // rows. Two swipes reach the clamped bottom.
        TestStep.iosSwipe(fromX: 200, fromY: 620, toX: 200, toY: 160, duration: 0.3)
        TestStep.iosSwipe(fromX: 200, fromY: 620, toX: 200, toY: 160, duration: 0.3)
        TestStep.iosWaitForElement(.label("Licenses"), timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.iosTap(.label("Licenses"))

        // The pushed licenses list renders the same shared rows. Assert on the
        // first rows only: iOS's `List` is lazy, so rows below the fold (the
        // tail of the table) aren't in the AX tree until scrolled into view.
        // The macOS section already asserts the full range including the last
        // row ("Unicode CLDR emoji data").
        TestStep.iosWaitForElement(.labelContains("SwiftTerm"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Sparkle"), timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.iosScreenshot(label: "ios-licenses-list")
    }
}
