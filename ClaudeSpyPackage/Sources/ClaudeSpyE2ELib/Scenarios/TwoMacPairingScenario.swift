import Foundation

/// E2E scenario: Pair two Mac apps (host + viewer), start a tmux session on the host,
/// verify it appears on the viewer, type a command from the viewer, and verify it on the host.
public enum TwoMacPairingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Two Mac Pairing",
        tags: ["pairing", "macos-only"]
    ) {
        // ── Phase 1–4: Pair two Mac apps (host + viewer) ────────────

        Shortcut.twoMacPairing

        // Diagnostic screenshots
        TestStep.macScreenshot(label: "host-after-pairing", compare: false)
        TestStep.macScreenshot(label: "viewer-after-pairing", compare: false, instance: 1)
        TestStep.macScreenshot(label: "host-connected")
        TestStep.macScreenshot(label: "viewer-connected", instance: 1)

        // ── Phase 5: Create tmux session on host ────────────────────

        TestStep.log("Creating tmux session on host")
        TestStep.tmuxCreateSession(name: "e2e-mac-pair", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        // ── Phase 6: Verify remote pane appears on viewer ───────────

        TestStep.log("Opening Panes window on viewer and verifying remote pane")
        TestStep.macOpenPanesWindow(instance: 1)
        TestStep.macWaitForWindow(titled: "Available Windows", timeout: 5, instance: 1)
        TestStep.wait(seconds: 3)

        // The remote pane should show in the sidebar with format "session:window.pane"
        TestStep.macWaitForElement(titled: "e2e-mac-pair", timeout: 15, instance: 1)
        TestStep.macScreenshot(label: "viewer-sees-remote-pane", instance: 1)

        // ── Phase 7: Select the pane on the viewer ──────────────────

        TestStep.log("Selecting remote pane on viewer")
        TestStep.macClickButton(titled: "e2e-mac-pair", instance: 1)
        TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "viewer-pane-selected", instance: 1)

        // ── Phase 8: Type a command from the viewer (rapid keystrokes) ─

        TestStep.log("Typing command from viewer into remote terminal (no charDelay)")
        TestStep.macType(text: "echo e2e-test-hello", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 3)

        // ── Phase 9: Verify command shows on the host's tmux pane ───

        // Verify the viewer's terminal UI shows the command
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("e2e-test-hello")]),
            timeout: 10,
            instance: 1
        )

        // Open the host's Panes window and select its session to visually verify
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Available Windows", timeout: 5)
        TestStep.macWaitForElement(titled: "e2e-mac-pair", timeout: 10)
        TestStep.macClickButton(titled: "e2e-mac-pair")
        TestStep.wait(seconds: 2)

        // Verify the host's terminal UI shows the command
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("e2e-test-hello")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "host-shows-command")
    }
}
