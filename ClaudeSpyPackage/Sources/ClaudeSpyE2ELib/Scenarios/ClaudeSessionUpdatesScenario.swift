import ClaudeSpyNetworking
import Foundation

/// E2E scenario: Claude session updates as appropriate
///
/// Builds on the Claude Sessions Show scenario. Verifies that:
/// 1. After UserPromptSubmit, the session indicator turns green (active, not needing attention)
/// 2. After SessionEnd, the pane returns to being a plain terminal
public enum ClaudeSessionUpdatesScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Claude Session Updates",
        tags: ["hooks", "sessions"]
    ) {
        // 1. Start with the Claude Sessions Show scenario
        //    (fresh pairing + 2 tmux sessions + SessionStart hook on pane 1)
        ClaudeSessionsShowScenario.scenario

        // 2. Send UserPromptSubmit hook — this clears needsAttention (green indicator)
        //    and flips the session to "Working" via update_session_status.
        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("UserPromptSubmit"),
                "session_id": .string("e2e-test-session-1"),
                "timestamp": .string("2026-02-14T10:01:00.000000Z"),
                "prompt": .string("Hello from e2e test"),
            ],
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject",
            sessionID: "e2e-test-session-1"
        )

        // 3. Verify iOS still shows the session (MyProject) and the row now
        //    reports "Working" via accessibilityValue. EventRowView's
        //    "Prompt Submitted" string is no longer rendered (Task 20).
        TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 10)
        TestStep.iosWaitForElement(.valueContains("Working"), timeout: 5)

        // 4. Send SessionEnd hook — session should be removed
        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("SessionEnd"),
                "session_id": .string("e2e-test-session-1"),
                "timestamp": .string("2026-02-14T10:02:00.000000Z"),
                "reason": .string("user_quit"),
            ],
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject",
            sessionID: "e2e-test-session-1"
        )

        // 5. Verify the session is gone — pane should now show as a plain terminal
        //    The pane still exists in tmux, so it should appear as a terminal row
        //    with the session name (not "MyProject" which was the Claude session name)
        TestStep.iosWaitForElementToDisappear(.labelContains("MyProject"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("session-1"), timeout: 5)
    }
}
