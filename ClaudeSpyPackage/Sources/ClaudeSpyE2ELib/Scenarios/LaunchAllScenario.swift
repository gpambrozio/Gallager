import Foundation

/// Launches server, iOS app, and macOS app without pairing — used by interactive mode
public enum LaunchAllScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Launch All",
        tags: ["interactive"]
    ) {
        // 1. Clean up any previous state
        TestStep.uninstallIOSApp
        TestStep.terminateMacApp

        // 2. Start server on localhost
        TestStep.startServer(port: 8_765)
        TestStep.verifyServerHealth

        // 3. Launch iOS in simulator
        TestStep.launchIOSApp(arguments: ["--e2e-test", "--server-url", "ws://127.0.0.1:8765"])
        TestStep.wait(seconds: 3)

        // 4. Launch macOS app
        TestStep.launchMacApp(arguments: [
            "--e2e-test",
            "--server-url", "ws://127.0.0.1:8765",
            "--tmux-socket", "/tmp/claudespy-e2e.sock",
        ])
        TestStep.wait(seconds: 3)
    }
}
