import Foundation

/// E2E scenario: When a host disconnects, both iOS and Mac viewers clear sessions
///
/// Verifies that after a host disconnects from the relay server,
/// both the iOS viewer and Mac viewer automatically clear all sessions for that host.
public enum HostDisconnectClearsSessionsScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Host Disconnect Clears Sessions",
        tags: ["sessions", "disconnect"]
    ) {
        // 1. Establish a fresh pairing (iOS + macOS host)
        FreshPairingScenario.scenario

        // 2. Add a Mac viewer (instance 1) paired with the host
        Shortcut.addMacViewer

        // 3. Create a tmux session so there's something to show
        TestStep.tmuxCreateSession(name: "work-session", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        // 4. Store the pane ID and send a SessionStart hook event
        TestStep.tmuxStorePaneId(target: "work-session:0.0", storeAs: "paneId")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-disconnect-test",
                "timestamp": "2026-04-06T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/DisconnectTest"
        )

        // 5. Verify iOS shows the Claude session
        TestStep.iosWaitForElement(.labelContains("DisconnectTest"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-sessions-before-disconnect", compare: false)

        // 6. Open Panes window on Mac viewer and verify remote session appears
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macWaitForElement(titled: "work-session", timeout: 15, instance: 1)
        TestStep.macScreenshot(label: "viewer-sessions-before-disconnect", compare: false, instance: 1)

        // 7. Disconnect the host from the relay server
        TestStep.serverBlockDevice(.host)

        // 8. Verify iOS no longer shows the session
        TestStep.iosWaitForElementToDisappear(.labelContains("DisconnectTest"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-sessions-after-disconnect", compare: false)

        // 9. Verify Mac viewer no longer shows the remote session
        TestStep.macWaitForElementToDisappear(titled: "work-session", timeout: 15, instance: 1)
        TestStep.macScreenshot(label: "viewer-sessions-after-disconnect", compare: false, instance: 1)
    }
}
