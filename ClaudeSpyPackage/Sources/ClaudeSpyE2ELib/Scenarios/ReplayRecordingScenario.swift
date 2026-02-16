import Foundation

/// E2E scenario: Replay a pre-recorded tmux session and verify it renders
/// correctly in the macOS mirror view.
public enum ReplayRecordingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Replay Recording",
        tags: ["recording", "macos-only"]
    ) {
        // ── Setup ──────────────────────────────────────────────────
        // Create a tmux session matching the recording dimensions.
        // Adjust width/height to match your recording's metadata.json.
        TestStep.tmuxCreateSession(name: "replay-test", width: 202, height: 68)

        TestStep.launchMacApp
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macResizeWindow(width: 1_200, height: 800)
        TestStep.macSetSidebarWidth(200)
        TestStep.wait(seconds: 1)

        // Select the pane
        TestStep.macClickButton(titled: "replay-test:0.0")
        TestStep.wait(seconds: 1)

        // ── Replay ─────────────────────────────────────────────────
        TestStep.tmuxReplayRecording(name: "FirstTest", target: "replay-test:0.0")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "replayed-terminal-bottom")

        TestStep.macScrollPage(up: true)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "replayed-terminal-1")

        TestStep.macScrollPage(up: true)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "replayed-terminal-2")

        TestStep.macScrollPage(up: true)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "replayed-terminal-3")

        TestStep.wait(seconds: 10)
    }
}
