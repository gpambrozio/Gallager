import ClaudeSpyNetworking
import Foundation

/// E2E scenario: Claude sessions show as appropriate
///
/// Verifies that after sending a SessionStart hook event, the iOS app
/// displays the pane as a Claude Code session with a red indicator
/// (needs attention), while the other pane remains a plain terminal.
public enum ClaudeSessionsShowScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Claude Sessions Show",
        tags: ["hooks", "sessions"]
    ) {
        // 1. Start with fresh pairing
        FreshPairingScenario.scenario

        // 2. Create 2 tmux sessions
        TestStep.tmuxCreateSession(name: "session-1", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "session-2", width: 80, height: 24)

        // 3. Store the pane IDs for later use in hook events
        TestStep.tmuxStorePaneId(target: "session-1:0.0", storeAs: "pane1Id")
        TestStep.tmuxStorePaneId(target: "session-2:0.0", storeAs: "pane2Id")

        // 4. Verify iOS shows both sessions as plain terminals
        TestStep.iosWaitForElement(.labelContains("session-1"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("session-2"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-plain-terminals")

        // 5. Send a SessionStart hook event for pane 1
        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("SessionStart"),
                "session_id": .string("e2e-test-session-1"),
                "timestamp": .string("2026-02-14T10:00:00.000000Z"),
            ],
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject",
            sessionID: "e2e-test-session-1"
        )

        // 6. Verify iOS now shows pane 1 as a Claude Code session
        //    - The session row should display the project folder name "MyProject"
        //    - After SessionStart, the indicator is red (needsAttention = true
        //      because SessionStart triggers a notification). The legacy
        //      EventRowView "Session Started" string is gone (Task 20); the
        //      row now exposes "Attention" via accessibilityValue.
        TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 10)
        TestStep.iosWaitForElement(.valueContains("Attention"), timeout: 5)

        // 7. Verify pane 2 is still shown as a plain terminal
        TestStep.iosWaitForElement(.labelContains("session-2"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-claude-session")
    }
}
