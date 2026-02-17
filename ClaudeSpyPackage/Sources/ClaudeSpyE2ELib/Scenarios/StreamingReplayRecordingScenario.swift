import Foundation

/// E2E scenario: Replay a pre-recorded tmux session with throttled streaming
/// so the mirror connects mid-stream. This reproduces the real-world garbling
/// bug where capture-pane gets partial state and remaining bytes arrive as
/// %output events.
public enum StreamingReplayRecordingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Streaming Replay Recording",
        tags: ["recording", "macos-only"]
    ) {
        // ── Setup ──────────────────────────────────────────────────
        // Create a tmux session matching the recording dimensions.
        TestStep.tmuxCreateSession(name: "replay-test", width: 202, height: 68)

        // ── Start streaming BEFORE the mirror connects ─────────────
        // This is the key difference from ReplayRecordingScenario:
        // data starts flowing into the pane before any mirror is watching.
        TestStep.tmuxReplayRecordingStreaming(
            name: "FirstTest",
            target: "replay-test:0.0",
            chunkSize: 512,
            chunkDelayMs: 30
        )

        // Let some content render (~50KB at 512b/30ms = ~3 seconds)
        TestStep.wait(seconds: 3)

        // ── Connect the mirror mid-stream ──────────────────────────
        TestStep.launchMacApp
        TestStep.wait(seconds: 2)

        TestStep.macOpenPanesWindow
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macResizeWindow(width: 1_200, height: 800)
        TestStep.macSetSidebarWidth(200)
        TestStep.wait(seconds: 1)

        // Select the pane — mirror connects and gets capture-pane + live %output
        TestStep.macClickButton(titled: "replay-test:0.0")

        // ── Wait for replay to complete ────────────────────────────
        // ~360KB at 512b/30ms ≈ 21s, plus buffer
        TestStep.wait(seconds: 25)

        // ── Screenshots (compare: false — timing-dependent output) ─
        TestStep.macScreenshot(label: "streaming-terminal-bottom", compare: false)

        TestStep.macScrollPage(up: true)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "streaming-terminal-1", compare: false)

        TestStep.macScrollPage(up: true)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "streaming-terminal-2", compare: false)

        TestStep.macScrollPage(up: true)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "streaming-terminal-3", compare: false)
    }
}
