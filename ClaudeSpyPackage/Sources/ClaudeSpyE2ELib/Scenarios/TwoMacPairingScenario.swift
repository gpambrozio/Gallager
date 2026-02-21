import Foundation

/// E2E scenario: Pair two Mac apps (host + viewer), start a tmux session on the host,
/// verify it appears on the viewer, type a command from the viewer, and verify it on the host.
public enum TwoMacPairingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Two Mac Pairing",
        tags: ["pairing", "macos-only"]
    ) {
        // ── Phase 1: Setup ──────────────────────────────────────────

        TestStep.log("Starting relay server")
        TestStep.startServer
        TestStep.verifyServerHealth

        // ── Phase 2: Launch host (mac1) and generate pairing code ───

        TestStep.log("Launching host Mac app (mac1)")
        TestStep.launchMacApp
        TestStep.wait(seconds: 3)

        TestStep.macOpenSettings
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.wait(seconds: 3)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "pairingCode")
        TestStep.log("Pairing code: ${pairingCode}")

        // ── Phase 3: Launch viewer (mac2) and pair with host ────────

        TestStep.log("Launching viewer Mac app (mac2)")
        TestStep.launchMac2App
        TestStep.wait(seconds: 3)

        TestStep.mac2OpenSettings
        TestStep.mac2WaitForWindow(titled: "General", timeout: 5)
        TestStep.mac2SelectSettingsTab("Remote Hosts")
        TestStep.wait(seconds: 1)

        // Click "Add Host" to open the pairing sheet
        TestStep.mac2ClickButton(titled: "Add Host")
        TestStep.wait(seconds: 1)

        // Type the pairing code into the sheet's text field
        TestStep.mac2Type(text: "${pairingCode}")
        TestStep.wait(seconds: 1)

        // Click "Connect" to complete pairing
        TestStep.mac2ClickButton(titled: "Connect")
        TestStep.wait(seconds: 5)

        // ── Phase 4: Verify pairing succeeded ───────────────────────

        TestStep.log("Verifying pairing and connections")
        TestStep.verifyServerHasPairings(count: 1)
        TestStep.waitForHostConnected(timeout: 15)
        TestStep.waitForViewerConnected(timeout: 15)

        // Verify host shows "Connected" on its settings page
        TestStep.macWaitForElement(titled: "Connected", timeout: 15)
        TestStep.macScreenshot(label: "host-connected", compare: false)

        // Verify viewer shows "Connected" on its Remote Hosts page
        TestStep.mac2WaitForElement(titled: "Connected", timeout: 15)
        TestStep.mac2Screenshot(label: "viewer-connected", compare: false)

        // ── Phase 5: Create tmux session on host ────────────────────

        TestStep.log("Creating tmux session on host")
        TestStep.tmuxCreateSession(name: "e2e-mac-pair", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        // ── Phase 6: Verify remote pane appears on viewer ───────────

        TestStep.log("Opening Panes window on viewer and verifying remote pane")
        TestStep.mac2OpenPanesWindow
        TestStep.mac2WaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 3)

        // The remote pane should show in the sidebar with format "session:window.pane"
        TestStep.mac2WaitForElement(titled: "e2e-mac-pair:0.0", timeout: 15)
        TestStep.mac2Screenshot(label: "viewer-sees-remote-pane", compare: false)

        // ── Phase 7: Select the pane on the viewer ──────────────────

        TestStep.log("Selecting remote pane on viewer")
        TestStep.mac2ClickButton(titled: "e2e-mac-pair:0.0")
        TestStep.wait(seconds: 3)
        TestStep.mac2Screenshot(label: "viewer-pane-selected", compare: false)

        // ── Phase 8: Type a command from the viewer ─────────────────

        TestStep.log("Typing command from viewer into remote terminal")
        TestStep.mac2Type(text: "echo e2e-test-hello")
        TestStep.wait(seconds: 1)
        TestStep.mac2Type(text: "", pressReturn: true)
        TestStep.wait(seconds: 3)

        // ── Phase 9: Verify command shows on the host's tmux pane ───

        TestStep.log("Verifying command appears in host's tmux pane")
        TestStep.tmuxCapturePaneContent(target: "e2e-mac-pair:0.0", storeAs: "paneContent")
        TestStep.assertStoredContains(key: "paneContent", substring: "e2e-test-hello")
        TestStep.macScreenshot(label: "host-shows-command", compare: false)
    }
}
