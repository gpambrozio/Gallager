import Foundation

/// E2E scenario: Terminal notification (OSC 9) detection
///
/// Verifies that when a terminal application sends an OSC 9 notification
/// escape sequence, the macOS app detects it and triggers the notification
/// service. In E2E mode the service writes to a log file instead of showing
/// a desktop notification, so this scenario reads the log to verify delivery.
public enum TerminalNotificationScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal Notification",
        tags: ["terminal", "notifications"]
    ) {
        // 1. Start with fresh pairing
        FreshPairingScenario.scenario

        // 2. Create a tmux session and store the pane ID
        TestStep.tmuxCreateSession(name: "notif-test", width: 80, height: 24)
        TestStep.wait(seconds: 2)
        TestStep.tmuxStorePaneId(target: "notif-test:0.0", storeAs: "paneId")

        // 3. Verify iOS shows the session
        TestStep.iosWaitForElement(.labelContains("notif-test"), timeout: 15)

        // 4. Send a SessionStart hook so the session appears as a Claude session
        //    (this causes the app to start monitoring the pane via PaneStreamManager)
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-notif-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/NotifTest"
        )
        TestStep.wait(seconds: 3)

        // 5. Open the terminal view from iOS to start streaming
        //    (streaming activates PipePaneReader which runs the notification parser)
        TestStep.iosTap(.labelContains("NotifTest"))
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting to terminal"), timeout: 15)
        TestStep.wait(seconds: 2)

        // 6. Send an OSC 9 notification escape sequence via the tmux pane
        TestStep.tmuxSendKeys(
            target: "notif-test:0.0",
            keys: "printf '\\e]9;E2E notification test\\a'",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "notif-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 3)

        // 7. Read the notification log written by the E2E notification service
        TestStep.readFile(path: "${notificationLogPath}", storeAs: "notificationLog")

        // 8. Verify the log contains the expected notification text
        TestStep.assertStoredContains(key: "notificationLog", substring: "E2E notification test")
    }
}
