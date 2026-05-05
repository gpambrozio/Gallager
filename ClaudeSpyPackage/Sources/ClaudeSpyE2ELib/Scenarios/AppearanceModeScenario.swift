import Foundation

/// E2E test for the Settings → Appearance picker on both macOS and iOS.
///
/// CI runs in light mode, so the System and Light selections produce
/// equivalent app chrome — only Dark flips the chrome to a dark
/// appearance. The scenario captures three baselines per platform so a
/// regression in `applyAppearance()` (macOS) or `.preferredColorScheme(_:)`
/// (iOS) wiring shows up as a screenshot diff on the dark baseline.
///
/// Pairing is required only to reach the iOS Settings sheet (which sits
/// behind the Sessions toolbar button, visible only after pairing). The
/// macOS portion piggy-backs on the same paired setup — we just switch
/// the Settings tab from "Remote Access" (left over from pairing) to
/// "Appearance".
public enum AppearanceModeScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Appearance Mode",
        tags: ["appearance", "settings"]
    ) {
        FreshPairingScenario.scenario

        // ── macOS ──────────────────────────────────────────────────

        TestStep.macSelectSettingsTab("Appearance")
        TestStep.macWaitForElement(titled: "Theme", timeout: 5)
        TestStep.wait(seconds: 0.5)

        // 1. Default System selected (light chrome in CI).
        TestStep.macScreenshot(label: "mac-appearance-default-system")

        // 2. Dark — chrome should repaint dark.
        TestStep.macClickButton(titled: "Dark")
        TestStep.wait(seconds: 1.5)
        TestStep.macScreenshot(label: "mac-appearance-dark")

        // 3. Light — chrome back to light, Light tile selected.
        TestStep.macClickButton(titled: "Light")
        TestStep.wait(seconds: 1.5)
        TestStep.macScreenshot(label: "mac-appearance-light")

        // Restore default before moving on so the persisted value matches
        // the shipped default at the end of the run.
        TestStep.macClickButton(titled: "System")
        TestStep.wait(seconds: 1)

        // ── iOS ────────────────────────────────────────────────────

        // Open the Settings sheet from the Sessions toolbar. The segmented
        // picker hides its title on iOS, so we wait for the visible
        // section header instead.
        TestStep.iosTap(.label("Settings"))
        TestStep.iosWaitForElement(.label("Appearance"), timeout: 5)
        TestStep.wait(seconds: 0.5)

        // 1. Default System (light scheme in CI).
        TestStep.iosScreenshot(label: "ios-appearance-default-system")

        // 2. Dark — `.preferredColorScheme(.dark)` flips the sheet.
        TestStep.iosTap(.label("Dark"))
        TestStep.wait(seconds: 1.5)
        TestStep.iosScreenshot(label: "ios-appearance-dark")

        // 3. Light — back to light scheme, Light segment selected.
        TestStep.iosTap(.label("Light"))
        TestStep.wait(seconds: 1.5)
        TestStep.iosScreenshot(label: "ios-appearance-light")

        // Restore default.
        TestStep.iosTap(.label("System"))
        TestStep.wait(seconds: 1)
    }
}
