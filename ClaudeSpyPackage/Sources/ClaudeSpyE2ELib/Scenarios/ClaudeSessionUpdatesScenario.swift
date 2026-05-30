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

        // 3. Verify iOS still shows the session (MyProject), now "Working" — a
        //    UserPromptSubmit puts the agent in its loop (the agent-blind status
        //    label), replacing the per-event "Prompt Submitted" row.
        TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("Working"), timeout: 5)

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

        // 5. After SessionEnd the agent session goes "Idle". The agent-blind model
        //    keeps the session badge (now idle) rather than reverting the pane to a
        //    plain terminal — a badge is reclaimed by pane detection, not the end
        //    hook (which doesn't apply to a synthetic e2e pane with no agent process).
        TestStep.iosWaitForElement(.labelContains("Idle"), timeout: 10)
        // Pane 2 remains a plain terminal throughout.
        TestStep.iosWaitForElement(.labelContains("session-2"), timeout: 5)
    }
}
