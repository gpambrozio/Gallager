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
        // ── Phase 1–4: Pair two Mac apps (host + viewer) ────────────

        Shortcut.twoMacPairing

        // ── Phase 5: Create tmux session on host ──────────────────────

        TestStep.log("Creating tmux session on host")
        TestStep.tmuxCreateSession(name: "e2e-title", width: 80, height: 24)

        // ── Phase 6: Open Panes window on host and select pane ────────

        TestStep.log("Opening Panes window on host")
        Shortcut.openPanesWindow()

        TestStep.macWaitForElement(titled: "e2e-title", timeout: 10)
        TestStep.macClickButton(titled: "e2e-title")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "host-default-title")

        // ── Phase 7: Set a custom terminal title via OSC escape seq ───

        TestStep.log("Setting custom terminal title via OSC 2 escape sequence")
        Shortcut.tmuxRunCommand(
            target: "e2e-title:0",
            command: "printf '\\033]2;E2E Custom Title\\007'",
            literal: false
        )

        // ── Phase 8: Verify title appears on host's sidebar ───────────

        TestStep.log("Verifying custom title appears on host sidebar")
        TestStep.macWaitForElement(titled: "E2E Custom Title", timeout: 10)
        TestStep.macScreenshot(label: "host-custom-title")

        // ── Phase 9: Open Panes on viewer, select pane, verify title ──

        TestStep.log("Opening Panes window on viewer and verifying title")
        TestStep.macOpenPanesWindow(instance: 1)
        TestStep.macWaitForWindow(titled: "Gallager", timeout: 5, instance: 1)

        TestStep.macWaitForElement(titled: "e2e-title", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "e2e-title", instance: 1)

        // Verify the title shows on the viewer's window
        TestStep.macWaitForElement(titled: "E2E Custom Title", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-custom-title", instance: 1)

        // ── Phase 10: Change title again and verify it updates ────────

        TestStep.log("Changing title again to verify live updates")
        Shortcut.tmuxRunCommand(
            target: "e2e-title:0",
            command: "printf '\\033]2;Updated Title\\007'",
            literal: false
        )

        // Verify updated title on both host and viewer
        TestStep.macWaitForElement(titled: "Updated Title", timeout: 10)
        TestStep.macScreenshot(label: "host-updated-title")

        TestStep.macWaitForElement(titled: "Updated Title", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-updated-title", instance: 1)
    }
}
