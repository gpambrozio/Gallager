import Foundation

/// E2E scenario: Unpair from macOS and verify iOS cleans up
public enum UnpairFromMacOSScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Unpair from macOS",
        tags: ["unpair"]
    ) {
        // 1. Establish a fresh pairing
        FreshPairingScenario.scenario

        // 2. Screenshot before unpair
        TestStep.macScreenshot(label: "mac-before-unpair")

        // 3. macOS: trigger unpair via test HTTP endpoint
        // (SwiftUI Menu creates native NSMenu popups invisible to the accessibility tree)
        TestStep.macUnpair()
        // Wait for the server to process the unpair and for the macOS UI to
        // settle (Generate button reappears) before taking the screenshot.
        TestStep.waitForNoPairings(timeout: 15)
        TestStep.macWaitForElement(titled: "Generate Pairing Code", timeout: 5)
        TestStep.macScreenshot(label: "mac-after-unpair")

        // 4. Verify server has 0 pairings
        TestStep.verifyServerHasPairings(count: 0)

        // 5. Verify iOS returns to pairing view
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 10)
        // Clear clipboard so the SwiftUI PasteButton is in a deterministic
        // disabled state — the pairing flow may have left a code on the board.
        TestStep.iosClearClipboard
        TestStep.iosScreenshot(label: "ios-back-to-pairing")
    }
}
