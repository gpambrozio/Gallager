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
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-test-session-1",
                "timestamp": "2026-02-14T10:01:00.000000Z",
                "prompt": "Hello from e2e test"
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )

        // 3. Verify iOS still shows the session (MyProject) with updated event
        TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("Prompt Submitted"), timeout: 5)

        // 4. Send SessionEnd hook — session should be removed
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionEnd",
                "session_id": "e2e-test-session-1",
                "timestamp": "2026-02-14T10:02:00.000000Z",
                "reason": "user_quit"
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )

        // 5. Verify the session is gone — pane should now show as a plain terminal
        //    The pane still exists in tmux, so it should appear as a terminal row
        //    with the session name (not "MyProject" which was the Claude session name)
        TestStep.iosWaitForElementToDisappear(.labelContains("MyProject"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("session-1"), timeout: 5)
    }
}
