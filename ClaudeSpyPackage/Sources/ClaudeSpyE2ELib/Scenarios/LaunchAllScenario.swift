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
        TestStep.startServer
        TestStep.verifyServerHealth

        // 3. Launch iOS in simulator
        TestStep.launchIOSApp
        TestStep.wait(seconds: 3)

        // 4. Launch macOS app
        TestStep.launchMacApp
        TestStep.wait(seconds: 3)
    }
}
