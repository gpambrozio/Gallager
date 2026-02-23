import Foundation

/// E2E scenario: Pair two Mac apps, then send rapid keystrokes from the viewer
/// multiple times and verify they arrive at the host in the correct order.
/// Reproduces and validates the fix for GitHub issue #165.
public enum RapidKeystrokeOrderScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Rapid Keystroke Order",
        tags: ["keystroke", "macos-only"]
    ) {
        // ── Phase 1: Setup ──────────────────────────────────────────
        TestStep.log("Starting relay server")
        TestStep.startServer
        TestStep.verifyServerHealth

        // ── Phase 2: Launch host and generate pairing code ──────────
        TestStep.log("Launching host Mac app")
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

        // ── Phase 3: Launch viewer and pair ─────────────────────────
        TestStep.log("Launching viewer Mac app and pairing")
        TestStep.launchMacApp(instance: 1)
        TestStep.wait(seconds: 3)

        TestStep.macOpenSettings(instance: 1)
        TestStep.macWaitForWindow(titled: "General", timeout: 5, instance: 1)
        TestStep.macSelectSettingsTab("Remote Hosts", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Add Host", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macFocusElement(titled: "Pairing Code", instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "${pairingCode}", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 5)

        // ── Phase 4: Verify pairing ─────────────────────────────────
        TestStep.verifyServerHasPairings(count: 1)
        TestStep.waitForHostConnected(timeout: 15)
        TestStep.waitForViewerConnected(timeout: 15)
        TestStep.macWaitForElement(titled: "Connected", timeout: 15)
        TestStep.macWaitForElement(titled: "Connected", timeout: 15, instance: 1)

        // ── Phase 5: Create tmux session on host ────────────────────
        TestStep.log("Creating tmux session on host")
        TestStep.tmuxCreateSession(name: "e2e-rapid-keys", width: 120, height: 24)
        TestStep.wait(seconds: 3)

        // ── Phase 6: Open Panes on viewer and select the remote pane ─
        TestStep.macOpenPanesWindow(instance: 1)
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5, instance: 1)
        TestStep.wait(seconds: 3)
        TestStep.macWaitForElement(titled: "e2e-rapid-keys:0.0", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "e2e-rapid-keys:0.0", instance: 1)
        TestStep.wait(seconds: 3)

        // ── Phase 7: Rapid keystroke tests ──────────────────────────
        // Send rapid keystrokes (no charDelay) and verify order.
        // We use distinguishable strings so transpositions are detectable.

        // Round 1: Type a string with all unique chars in rapid succession
        TestStep.log("Round 1: Rapid typing 'abcdefghij'")
        TestStep.macType(text: "echo round1-abcdefghij", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 3)
        TestStep.tmuxCapturePaneContent(target: "e2e-rapid-keys:0.0", storeAs: "round1")
        TestStep.assertStoredContains(key: "round1", substring: "round1-abcdefghij")

        // Round 2: A longer string to increase likelihood of reordering
        TestStep.log("Round 2: Rapid typing 'the-quick-brown-fox'")
        TestStep.macType(text: "echo round2-the-quick-brown-fox", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 3)
        TestStep.tmuxCapturePaneContent(target: "e2e-rapid-keys:0.0", storeAs: "round2")
        TestStep.assertStoredContains(key: "round2", substring: "round2-the-quick-brown-fox")

        // Round 3: Numbers and special chars
        TestStep.log("Round 3: Rapid typing '1234567890'")
        TestStep.macType(text: "echo round3-1234567890", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 3)
        TestStep.tmuxCapturePaneContent(target: "e2e-rapid-keys:0.0", storeAs: "round3")
        TestStep.assertStoredContains(key: "round3", substring: "round3-1234567890")

        // Round 4: Mixed case to catch case-sensitive ordering bugs
        TestStep.log("Round 4: Rapid typing mixed case")
        TestStep.macType(text: "echo round4-AaBbCcDdEe", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 3)
        TestStep.tmuxCapturePaneContent(target: "e2e-rapid-keys:0.0", storeAs: "round4")
        TestStep.assertStoredContains(key: "round4", substring: "round4-AaBbCcDdEe")

        // ── Phase 8: Screenshot both panes for visual verification ────
        TestStep.log("Taking screenshots of both host and viewer panes")

        // Open the host's Panes window and select its pane so the screenshot shows the terminal
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.macWaitForElement(titled: "e2e-rapid-keys:0.0", timeout: 10)
        TestStep.macClickButton(titled: "e2e-rapid-keys:0.0")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "host-after-keystrokes")
        TestStep.macScreenshot(label: "viewer-after-keystrokes", instance: 1)
    }
}
