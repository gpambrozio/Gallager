import Foundation

/// E2E test for the macOS Settings → Appearance tab.
///
/// CI runs in light mode, so the System and Light tiles produce visually
/// equivalent app chrome — only the Dark tile flips the chrome to a dark
/// appearance. The scenario captures three baselines:
///
/// 1. Default state (System selected, light chrome).
/// 2. After clicking Dark — chrome should repaint dark.
/// 3. After clicking Light — chrome back to light, but a different tile
///    is selected than in #1.
///
/// If `applyAppearance()` regresses (e.g. NSApp.appearance stops being
/// applied, or .dark stops mapping to `darkAqua`), the second baseline
/// will fall back to the light chrome and the comparison will break.
public enum AppearanceModeScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Appearance Mode",
        tags: ["appearance", "settings", "macos-only"]
    ) {
        // 1. Launch the macOS app. We deliberately skip opening the Panes
        //    window — the Settings window alone makes the screenshot target
        //    deterministic regardless of which window CGWindowList orders
        //    first.
        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        // 2. Open Settings and switch to the new Appearance tab.
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Appearance")
        TestStep.macWaitForElement(titled: "Theme", timeout: 5)
        TestStep.wait(seconds: 0.5)

        // The SwiftUI Settings window pins itself to its content's
        // `frame(minWidth: 900, minHeight: 500)`, which is deterministic
        // enough for baselines without an explicit resize step (and the
        // panel-backed Settings window doesn't expose itself via
        // `kAXWindowsAttribute` so AX-based resize wouldn't work anyway).

        // 3. Default state: System selected. CI runs light, so the chrome
        //    is rendered with the light appearance.
        TestStep.macScreenshot(label: "mac-appearance-default-system")

        // 4. Switch to Dark — NSApp.appearance flips to darkAqua and the
        //    Settings window chrome repaints dark.
        TestStep.macClickButton(titled: "Dark")
        TestStep.wait(seconds: 1.5)
        TestStep.macScreenshot(label: "mac-appearance-dark")

        // 5. Switch to Light — chrome back to light, Light tile selected.
        TestStep.macClickButton(titled: "Light")
        TestStep.wait(seconds: 1.5)
        TestStep.macScreenshot(label: "mac-appearance-light")

        // 6. Restore the System default so any persisted state hint at
        //    the end of the run reflects the shipped default.
        TestStep.macClickButton(titled: "System")
        TestStep.wait(seconds: 1)
    }
}
