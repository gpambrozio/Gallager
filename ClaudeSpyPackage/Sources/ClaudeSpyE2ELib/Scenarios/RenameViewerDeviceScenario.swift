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

        // 2. Open iOS Settings and focus the Device Name field. The
        //    FreshPairingScenario above runs `uninstallIOSApp` first, so the
        //    field starts empty — no select-all-then-overwrite is needed.
        TestStep.iosTap(.label("Settings"))
        TestStep.iosWaitForElement(.label("Device Name"), timeout: 5)
        // The Section header is queryable as soon as the sheet starts
        // animating in, but the embedded TextField doesn't reliably accept
        // synthesized taps until the sheet finishes settling — a tap that
        // races the animation lands without focusing the field, so the
        // subsequent `iosType` keystrokes go nowhere. Hold here so the
        // sheet is fully interactive before we tap the field.
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.identifier("device-name-field"))
        TestStep.wait(seconds: 0.5)

        // 3. Type the new name and let the keyboard "return" key submit it.
        //    `\n` over `_XCT_sendString` triggers SwiftUI's `.onSubmit`, which
        //    calls `commitDeviceName()` and disconnects+reconnects the viewer.
        TestStep.iosType(text: "E2E Test iPhone\n")
        TestStep.wait(seconds: 0.5)

        // 4. Close the Settings sheet. Dismissing it also drops focus from
        //    the field (a belt-and-suspenders trigger for `commitDeviceName`
        //    via the `.onChange(of: deviceNameFieldFocused)` callback if
        //    `.onSubmit` somehow didn't fire), and lets the user see the
        //    rename land in the Sessions list.
        TestStep.iosTap(.label("Done"))
        TestStep.iosWaitForElementToDisappear(.label("Device Name"), timeout: 5)

        // 5. The iOS commit triggers a disconnect+reconnect that re-registers
        //    the viewer with the new name. Allow time for the round-trip.
        TestStep.macWaitForElement(titled: "E2E Test iPhone", timeout: 20)
        TestStep.macScreenshot(label: "mac-viewer-renamed", tolerance: 5)

        // 6. Wait for the viewer to reconnect after the rename so the
        //    scenario ends in a steady state.
        TestStep.waitForViewerConnected(timeout: 15)
    }
}
