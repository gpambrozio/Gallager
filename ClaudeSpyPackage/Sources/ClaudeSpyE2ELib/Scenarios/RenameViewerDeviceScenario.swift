import Foundation

/// E2E scenario: Rename the iOS device after pairing and verify the new name
/// propagates to the macOS "Paired Viewers" cell.
///
/// Before issue #465, the cell was hardcoded to "Viewer". We now expect the
/// custom name the iOS user typed in Settings.
public enum RenameViewerDeviceScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Rename Viewer Device",
        tags: ["pairing"]
    ) {
        // 1. Establish a fresh pairing.
        FreshPairingScenario.scenario

        // 2. Open iOS Settings and focus the Device Name field.
        TestStep.iosTap(.label("Settings"))
        TestStep.iosWaitForElement(.label("Device Name"), timeout: 5)
        TestStep.iosTap(.identifier("device-name-field"))
        TestStep.wait(seconds: 0.5)

        // 3. Replace whatever is in the field. `iosType` appends, so on a
        //    re-run after a partial failure the field could already hold
        //    "E2E Test iPhone" — sending Ctrl-A first selects all so the
        //    next characters overwrite instead of producing
        //    "E2E Test iPhoneE2E Test iPhone".
        TestStep.iosType(text: "\u{0001}E2E Test iPhone\n")
        TestStep.wait(seconds: 0.5)

        // 4. The iOS commit triggers a disconnect+reconnect that re-registers
        //    the viewer with the new name. Allow time for the round-trip.
        TestStep.macWaitForElement(titled: "E2E Test iPhone", timeout: 20)
        TestStep.macScreenshot(label: "mac-viewer-renamed", tolerance: 5)

        // 5. Wait for the viewer to reconnect after the rename so the
        //    scenario ends in a steady state.
        TestStep.waitForViewerConnected(timeout: 15)

        // 6. Close the iOS Settings sheet to leave the Sessions list visible.
        TestStep.iosTap(.label("Done"))
        TestStep.iosWaitForElementToDisappear(.label("Device Name"), timeout: 5)
    }
}
