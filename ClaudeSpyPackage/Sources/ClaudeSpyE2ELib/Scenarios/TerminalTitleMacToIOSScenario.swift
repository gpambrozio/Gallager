import Foundation

/// E2E scenario: Verify terminal title propagation from macOS host to iOS viewer.
///
/// 1. Pair macOS host with iOS simulator
/// 2. Create a tmux session on the host
/// 3. Set a custom title via OSC escape sequence
/// 4. Verify the title appears on the host's sidebar
/// 5. Open the pane on iOS and verify the title appears in the navigation bar
public enum TerminalTitleMacToIOSScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal Title Mac-to-iOS",
        tags: ["terminal-title", "smoke"]
    ) {
        // ── Phase 1: Pair macOS host with iOS simulator ───────────────

        // Reuse the full pairing flow
        FreshPairingScenario.scenario

        // ── Phase 2: Create tmux session on host ──────────────────────

        TestStep.log("Creating tmux session on host")
        TestStep.tmuxCreateSession(name: "e2e-title-ios", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        // ── Phase 3: Open Panes window on host and select pane ────────

        TestStep.log("Opening Panes window on host")
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_000, height: 600)
        TestStep.macSetSidebarWidth(250)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElement(titled: "e2e-title-ios:0.0", timeout: 10)
        TestStep.macClickButton(titled: "e2e-title-ios:0.0")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "host-default-title")

        // ── Phase 4: Set custom terminal title via OSC escape seq ─────

        TestStep.log("Setting custom terminal title via OSC 2 escape sequence")
        TestStep.tmuxSendKeys(
            target: "e2e-title-ios:0.0",
            keys: "printf '\\033]2;iOS Title Test\\007'",
            literal: false
        )
        TestStep.tmuxSendKeys(target: "e2e-title-ios:0.0", keys: "Enter", literal: false)
        TestStep.wait(seconds: 3)

        // ── Phase 5: Verify title appears on host's sidebar ───────────

        TestStep.log("Verifying custom title appears on host sidebar")
        TestStep.macWaitForElement(titled: "iOS Title Test", timeout: 10)
        TestStep.macScreenshot(label: "host-custom-title")

        // ── Phase 6: Navigate to pane on iOS and verify title ─────────

        TestStep.log("Selecting pane on iOS to view terminal")
        // The iOS app should show the sessions/panes list. Tap the pane.
        TestStep.iosWaitForElement(.labelContains("e2e-title-ios"), timeout: 15)
        TestStep.iosTap(.labelContains("e2e-title-ios"))
        TestStep.wait(seconds: 3)

        // Wait for the terminal to connect and start streaming
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
        TestStep.wait(seconds: 3)

        // Verify the terminal title appears in the iOS navigation title
        TestStep.iosWaitForElement(.labelContains("iOS Title Test"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-custom-title")

        // ── Phase 7: Change title and verify it updates on iOS ────────

        TestStep.log("Changing title and verifying live update on iOS")
        TestStep.tmuxSendKeys(
            target: "e2e-title-ios:0.0",
            keys: "printf '\\033]2;Updated iOS Title\\007'",
            literal: false
        )
        TestStep.tmuxSendKeys(target: "e2e-title-ios:0.0", keys: "Enter", literal: false)
        TestStep.wait(seconds: 3)

        // Verify updated title on host
        TestStep.macWaitForElement(titled: "Updated iOS Title", timeout: 10)
        TestStep.macScreenshot(label: "host-updated-title")

        // Verify updated title on iOS
        TestStep.iosWaitForElement(.labelContains("Updated iOS Title"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-updated-title")

        // ── Phase 8: Inactive pane title propagation to iOS ─────────

        TestStep.log("Creating second tmux session and setting its title while iOS views the first")
        TestStep.tmuxCreateSession(name: "e2e-title-ios2", width: 80, height: 24)

        // Wait for the pane to be discovered by periodic refresh and appear in sidebar
        // (notification reader must be running before we set the title)
        TestStep.macWaitForElement(titled: "e2e-title-ios2:0.0", timeout: 15)

        // Set a title on the new (inactive) pane — iOS is still viewing the first pane
        TestStep.tmuxSendKeys(
            target: "e2e-title-ios2:0.0",
            keys: "printf '\\033]2;Inactive iOS Title\\007'",
            literal: false
        )
        TestStep.tmuxSendKeys(target: "e2e-title-ios2:0.0", keys: "Enter", literal: false)
        TestStep.wait(seconds: 3)

        // Verify the inactive pane's title appears on the host sidebar
        TestStep.macWaitForElement(titled: "Inactive iOS Title", timeout: 10)
        TestStep.macScreenshot(label: "host-inactive-pane-title")

        // Navigate back to the iOS session list
        TestStep.iosTap(.labelContains("Sessions"))
        TestStep.wait(seconds: 2)

        // Select the second pane on iOS
        TestStep.iosWaitForElement(.labelContains("e2e-title-ios2"), timeout: 15)
        TestStep.iosTap(.labelContains("e2e-title-ios2"))
        TestStep.wait(seconds: 3)

        // Wait for connection
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
        TestStep.wait(seconds: 3)

        // Verify the title that was set while the pane was inactive appears on iOS
        TestStep.iosWaitForElement(.labelContains("Inactive iOS Title"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-inactive-pane-title")
    }
}
