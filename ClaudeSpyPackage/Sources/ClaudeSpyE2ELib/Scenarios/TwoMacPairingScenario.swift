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
        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        TestStep.macOpenSettings()
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
        TestStep.launchMacApp(instance: 1)
        TestStep.wait(seconds: 3)

        TestStep.macOpenSettings(instance: 1)
        TestStep.macWaitForWindow(titled: "General", timeout: 5, instance: 1)
        TestStep.macSelectSettingsTab("Remote Hosts", instance: 1)
        TestStep.wait(seconds: 1)

        // Click "Add Host" to open the pairing sheet
        TestStep.macClickButton(titled: "Add Host", instance: 1)
        TestStep.wait(seconds: 1)

        // Focus the text field, type the pairing code, then press Return to trigger Connect
        TestStep.macFocusElement(titled: "Pairing Code", instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "${pairingCode}", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 5)

        // ── Phase 4: Verify pairing succeeded ───────────────────────

        TestStep.log("Verifying pairing and connections")
        // Screenshot both apps before asserting so we can diagnose failures
        TestStep.macScreenshot(label: "host-after-pairing", compare: false)
        TestStep.macScreenshot(label: "viewer-after-pairing", compare: false, instance: 1)
        TestStep.verifyServerHasPairings(count: 1)
        TestStep.waitForHostConnected(timeout: 15)
        TestStep.waitForViewerConnected(timeout: 15)

        // Verify host shows "Connected" on its settings page
        TestStep.macWaitForElement(titled: "Connected", timeout: 15)
        TestStep.macScreenshot(label: "host-connected")

        // Verify viewer shows "Connected" on its Remote Hosts page
        TestStep.macWaitForElement(titled: "Connected", timeout: 15, instance: 1)
        TestStep.macScreenshot(label: "viewer-connected", instance: 1)

        // ── Phase 5: Create tmux session on host ────────────────────

        TestStep.log("Creating tmux session on host")
        TestStep.tmuxCreateSession(name: "e2e-mac-pair", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        // ── Phase 6: Verify remote pane appears on viewer ───────────

        TestStep.log("Opening Panes window on viewer and verifying remote pane")
        TestStep.macOpenPanesWindow(instance: 1)
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5, instance: 1)
        TestStep.wait(seconds: 3)

        // The remote pane should show in the sidebar with format "session:window.pane"
        TestStep.macWaitForElement(titled: "e2e-mac-pair:0.0", timeout: 15, instance: 1)
        TestStep.macScreenshot(label: "viewer-sees-remote-pane", instance: 1)

        // ── Phase 7: Select the pane on the viewer ──────────────────

        TestStep.log("Selecting remote pane on viewer")
        TestStep.macClickButton(titled: "e2e-mac-pair:0.0", instance: 1)
        TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "viewer-pane-selected", instance: 1)

        // ── Phase 8: Type a command from the viewer (rapid keystrokes) ─

        TestStep.log("Typing command from viewer into remote terminal (no charDelay)")
        TestStep.macType(text: "echo e2e-test-hello", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 3)

        // ── Phase 9: Verify command shows on the host's tmux pane ───

        TestStep.log("Verifying command appears in host's tmux pane")
        TestStep.tmuxCapturePaneContent(target: "e2e-mac-pair:0.0", storeAs: "paneContent")
        TestStep.assertStoredContains(key: "paneContent", substring: "e2e-test-hello")

        // Open the host's Panes window and select its session to visually verify
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.macWaitForElement(titled: "e2e-mac-pair:0.0", timeout: 10)
        TestStep.macClickButton(titled: "e2e-mac-pair:0.0")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "host-shows-command")
    }
}
