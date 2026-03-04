import Foundation

/// E2E scenario: Terminal notification (OSC 9) detection lifecycle
///
/// Tests the full notification monitoring lifecycle:
/// 1. **Background**: Notification detected with no mirror/streaming (notification-only reader)
/// 2. **Streaming**: Notification detected while iOS is actively streaming (full PaneStream)
/// 3. **Resumed**: Notification detected after streaming stops (reader restarts automatically)
///
/// In E2E mode the notification service writes to a log file instead of showing
/// desktop notifications, so this scenario reads the log to verify delivery.
public enum TerminalNotificationScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal Notification",
        tags: ["terminal", "notifications"]
    ) {
        // 1. Start with fresh pairing (sets up server, macOS app, iOS app, and E2EE)
        FreshPairingScenario.scenario

        // 2. Create a tmux session and store the pane ID
        TestStep.tmuxCreateSession(name: "notif-test", width: 80, height: 24)
        TestStep.wait(seconds: 2)
        TestStep.tmuxStorePaneId(target: "notif-test:0.0", storeAs: "paneId")

        // ═══════════════════════════════════════════════════════════════════
        // Phase 1: Background notification (no mirror, no streaming)
        // ═══════════════════════════════════════════════════════════════════

        // 3. Wait for the periodic pane refresh to discover the new pane and
        //    start a notification-only reader (refresh interval is 10s)
        TestStep.log("Phase 1: Testing background notification (no mirror, no streaming)")
        TestStep.wait(seconds: 12)

        // 4. Send OSC 9 notification — notification-only reader should detect it
        TestStep.tmuxSendKeys(
            target: "notif-test:0.0",
            keys: "printf '\\e]9;E2E background notification\\a'",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "notif-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 3)

        // 5. Verify background notification was logged
        TestStep.readFile(path: "${notificationLogPath}", storeAs: "notificationLog")
        TestStep.assertStoredContains(key: "notificationLog", substring: "E2E background notification")

        // ═══════════════════════════════════════════════════════════════════
        // Phase 2: Notification during active streaming
        // ═══════════════════════════════════════════════════════════════════

        // 6. Send a SessionStart hook so the session appears as a Claude session on iOS
        TestStep.log("Phase 2: Testing notification during active streaming")
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

        // 7. Open the terminal view from iOS to start streaming
        //    (notification reader stops, full PaneStream takes over)
        TestStep.iosTap(.labelContains("NotifTest"))
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting to terminal"), timeout: 15)
        TestStep.wait(seconds: 2)

        // 8. Send notification while streaming — full stream should detect it
        TestStep.tmuxSendKeys(
            target: "notif-test:0.0",
            keys: "printf '\\e]9;E2E streaming notification\\a'",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "notif-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 3)

        // 9. Verify streaming notification was logged
        TestStep.readFile(path: "${notificationLogPath}", storeAs: "notificationLog2")
        TestStep.assertStoredContains(key: "notificationLog2", substring: "E2E streaming notification")

        // ═══════════════════════════════════════════════════════════════════
        // Phase 3: Notification after deselecting (reader restarts)
        // ═══════════════════════════════════════════════════════════════════

        // 10. Navigate back to sessions list — iOS sends stopTerminalStream,
        //     PaneStreamManager.unsubscribe() restarts the notification reader
        TestStep.log("Phase 3: Testing notification after deselecting (reader restarts)")
        TestStep.iosTap(.labelContains("Sessions"))
        TestStep.wait(seconds: 3)

        // 11. Send notification — restarted notification reader should detect it
        TestStep.tmuxSendKeys(
            target: "notif-test:0.0",
            keys: "printf '\\e]9;E2E resumed notification\\a'",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "notif-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 3)

        // 12. Verify resumed notification was logged
        TestStep.readFile(path: "${notificationLogPath}", storeAs: "notificationLog3")
        TestStep.assertStoredContains(key: "notificationLog3", substring: "E2E resumed notification")
    }
}
