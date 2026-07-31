import Foundation

/// E2E scenario: the relay's pairing-pause maintenance switch
/// (`PAIRING_PAUSED_MESSAGE`, PR #704).
///
/// The relay boots with the pause enabled, carrying a realistic ~93-character
/// operator message (the docs' recommended length ceiling). A Mac host tries
/// to generate a pairing code; the relay refuses the registration with a
/// `PAIRING_PAUSED` error whose message is the operator's text, and the
/// pairing UI shows that text verbatim in its error state with a "Try Again"
/// button — proving the switch needs no client-side support.
public enum PairingPauseScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Pairing Pause",
        tags: ["pairing", "pairing-pause", "macos-only"]
    ) {
        // 1. Relay with the pairing-pause switch enabled.
        TestStep.startServerWithPairingPausedMessage(
            message: "Pairing is paused for server maintenance. Existing pairings are unaffected — try again later."
        )
        TestStep.verifyServerHealth

        // 2. Mac host tries to generate a pairing code.
        TestStep.launchMacApp(instance: 0)
        TestStep.wait(seconds: 3)
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Generate Pairing Code")

        // 3. The relay refuses the registration; the operator's message is
        //    shown verbatim in the pairing UI's error state.
        TestStep.macWaitForElement(titled: "paused for server maintenance", timeout: 15)
        TestStep.macWaitForElement(titled: "Try Again", timeout: 5)
        // Let the settings pane's overlay scroll indicator fade out — capturing
        // it mid-fade makes the baseline nondeterministic.
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-pairing-paused-message", tolerance: 5)
    }
}
