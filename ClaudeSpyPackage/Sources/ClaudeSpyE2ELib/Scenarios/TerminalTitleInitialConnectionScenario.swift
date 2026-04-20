import Foundation

/// E2E scenario: Verify terminal title is sent to remote viewer on initial connection.
///
/// Regression test for the fix where titles set during active pipe-pane streaming
/// were not forwarded to viewers connecting after the title was set.
///
/// Key: the tmux session is created and the title is set BEFORE the iOS app
/// is even launched, so the title can only reach the viewer through the
/// initial-connection path in TerminalStreamService, not via a real-time broadcast.
///
/// Flow:
/// 1. Start server and launch macOS host only (no iOS yet)
/// 2. Create tmux session, start streaming, set title
/// 3. Verify the host shows the title
/// 4. Launch iOS app, pair with host
/// 5. iOS viewer connects to the session
/// 6. Verify the iOS viewer receives the pre-existing title
public enum TerminalTitleInitialConnectionScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal Title Initial Connection",
        tags: ["terminal-title", "pairing"]
    ) {
        // ── Phase 1: Start server and launch macOS host only ─────────

        TestStep.uninstallIOSApp
        TestStep.terminateMacApp()

        TestStep.startServer
        TestStep.verifyServerHealth

        TestStep.launchMacApp()

        // ── Phase 2: Create tmux session, stream it, set title ───────

        TestStep.log("Creating tmux session on host")
        TestStep.tmuxCreateSession(name: "e2e-title-init", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        TestStep.log("Opening Panes window on host and selecting session to start streaming")
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "e2e-title-init", timeout: 10)
        TestStep.macClickButton(titled: "e2e-title-init")
        TestStep.wait(seconds: 2)

        TestStep.log("Setting terminal title via OSC 2 during active streaming")
        Shortcut.tmuxRunCommand(
            target: "e2e-title-init:0",
            command: "printf '\\033]2;Initial Connection Title\\007'",
            literal: false
        )
        TestStep.wait(seconds: 3)

        // ── Phase 3: Verify host shows the title ─────────────────────

        TestStep.log("Verifying title appears on host sidebar")
        TestStep.macWaitForElement(titled: "Initial Connection Title", timeout: 10)
        TestStep.macScreenshot(label: "host-has-title-before-ios-connects")

        // ── Phase 4: NOW launch iOS and pair ─────────────────────────
        // Title is already set and stored. iOS can only get it via initial connection.

        TestStep.log("Launching iOS app — title was set before iOS exists")
        TestStep.launchIOSApp()
        TestStep.iosWaitForElement(.labelContains("pairing code"), timeout: 15)

        // Generate pairing code on macOS
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "pairingCode")

        // Enter code on iOS
        TestStep.iosType(text: "${pairingCode}")

        // Verify pairing succeeded
        TestStep.iosWaitForElement(.labelContains("Sessions"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("Connected"), timeout: 15)
        TestStep.verifyServerHasPairings(count: 1)
        TestStep.waitForHostConnected(timeout: 15)
        TestStep.waitForViewerConnected(timeout: 15)
        TestStep.macWaitForElement(titled: "Connected", timeout: 15)

        // ── Phase 5: iOS viewer connects to the session ──────────────

        TestStep.log("iOS viewer connecting — should receive pre-existing title on initial connection")
        Shortcut.iosConnectToSession(sessionName: "e2e-title-init")

        // The title should appear in the iOS navigation bar immediately
        TestStep.iosWaitForElement(.labelContains("Initial Connection Title"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-receives-title-on-initial-connection")
    }
}
