import Foundation

/// E2E scenario: Verify terminal title propagation between two paired Mac apps (host + viewer).
///
/// 1. Pair two Mac apps
/// 2. Create a tmux session on the host, open the Panes window, check default title
/// 3. Set a custom title via OSC escape sequence
/// 4. Verify the title appears in the host's sidebar and window
/// 5. Open the same pane on the viewer and verify the title propagates
public enum TerminalTitleMacToMacScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal Title Mac-to-Mac",
        tags: ["terminal-title", "macos-only"]
    ) {
        // ── Phase 1: Setup relay server ───────────────────────────────

        TestStep.log("Starting relay server")
        TestStep.startServer
        TestStep.verifyServerHealth

        // ── Phase 2: Launch host (mac1) and generate pairing code ─────

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

        // ── Phase 3: Launch viewer (mac2) and pair with host ──────────

        TestStep.log("Launching viewer Mac app (mac2)")
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

        // ── Phase 4: Verify pairing ───────────────────────────────────

        TestStep.verifyServerHasPairings(count: 1)
        TestStep.waitForHostConnected(timeout: 15)
        TestStep.waitForViewerConnected(timeout: 15)
        TestStep.macWaitForElement(titled: "Connected", timeout: 15)
        TestStep.macWaitForElement(titled: "Connected", timeout: 15, instance: 1)

        // ── Phase 5: Create tmux session on host ──────────────────────

        TestStep.log("Creating tmux session on host")
        TestStep.tmuxCreateSession(name: "e2e-title", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        // ── Phase 6: Open Panes window on host and select pane ────────

        TestStep.log("Opening Panes window on host")
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Available Windows", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_000, height: 600)
        TestStep.macSetSidebarWidth(250)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElement(titled: "e2e-title:0", timeout: 10)
        TestStep.macClickButton(titled: "e2e-title:0")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "host-default-title")

        // ── Phase 7: Set a custom terminal title via OSC escape seq ───

        TestStep.log("Setting custom terminal title via OSC 2 escape sequence")
        TestStep.tmuxSendKeys(
            target: "e2e-title:0",
            keys: "printf '\\033]2;E2E Custom Title\\007'",
            literal: false
        )
        // Press Enter to execute the printf command
        TestStep.tmuxSendKeys(target: "e2e-title:0", keys: "Enter", literal: false)
        TestStep.wait(seconds: 3)

        // ── Phase 8: Verify title appears on host's sidebar ───────────

        TestStep.log("Verifying custom title appears on host sidebar")
        TestStep.macWaitForElement(titled: "E2E Custom Title", timeout: 10)
        TestStep.macScreenshot(label: "host-custom-title")

        // ── Phase 9: Open Panes on viewer, select pane, verify title ──

        TestStep.log("Opening Panes window on viewer and verifying title")
        TestStep.macOpenPanesWindow(instance: 1)
        TestStep.macWaitForWindow(titled: "Available Windows", timeout: 5, instance: 1)
        TestStep.wait(seconds: 3)

        TestStep.macWaitForElement(titled: "e2e-title:0", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "e2e-title:0", instance: 1)
        TestStep.wait(seconds: 3)

        // Verify the title shows on the viewer's window
        TestStep.macWaitForElement(titled: "E2E Custom Title", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-custom-title", instance: 1)

        // ── Phase 10: Change title again and verify it updates ────────

        TestStep.log("Changing title again to verify live updates")
        TestStep.tmuxSendKeys(
            target: "e2e-title:0",
            keys: "printf '\\033]2;Updated Title\\007'",
            literal: false
        )
        TestStep.tmuxSendKeys(target: "e2e-title:0", keys: "Enter", literal: false)
        TestStep.wait(seconds: 3)

        // Verify updated title on both host and viewer
        TestStep.macWaitForElement(titled: "Updated Title", timeout: 10)
        TestStep.macScreenshot(label: "host-updated-title")

        TestStep.macWaitForElement(titled: "Updated Title", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-updated-title", instance: 1)
    }
}
