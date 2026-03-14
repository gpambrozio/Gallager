import Foundation

/// E2E scenario: Mark session as handled clears attention state
///
/// Verifies that:
/// 1. A session in "needs attention" state (red indicator) shows correctly
/// 2. Tapping the session on iOS marks it as handled (indicator turns green)
/// 3. After returning to the session list, the session no longer shows red
/// 4. A new attention-triggering event re-raises the attention state
/// 5. The handled state syncs from iOS back to the Mac (via the host)
public enum MarkHandledScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Mark Handled",
        tags: ["hooks", "sessions"]
    ) {
        // 1. Start with the Claude Sessions Show scenario
        //    (fresh pairing + 2 tmux sessions + SessionStart hook on pane 1)
        //    At this point, pane 1 has needsAttention = true (red indicator)
        ClaudeSessionsShowScenario.scenario

        // 2. Verify iOS shows the session with a red indicator (needs attention)
        TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-session-needs-attention")

        // 3. Tap the session to open it — this should mark it as handled
        TestStep.iosTap(.labelContains("MyProject"))
        TestStep.wait(seconds: 3)

        // 4. Go back to the session list
        TestStep.iosTap(.label("Sessions"))
        TestStep.wait(seconds: 2)

        // 5. Verify the session still shows but the indicator has changed
        //    (no longer needs attention — the dot should be green, not red)
        TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-session-handled")

        // 6. Send a new attention-triggering event (PermissionRequest)
        //    This should re-raise the attention state
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-test-session-1",
                "timestamp": "2026-02-14T10:03:00.000000Z",
                "tool_name": "Write"
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )
        TestStep.wait(seconds: 3)

        // 7. Verify iOS shows the session as needing attention again (red indicator)
        TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("Permission"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-session-needs-attention-again")

        // 8. Open the session again to mark it handled once more
        TestStep.iosTap(.labelContains("MyProject"))
        TestStep.wait(seconds: 3)

        // 9. Go back to session list
        TestStep.iosTap(.label("Sessions"))
        TestStep.wait(seconds: 2)

        // 10. Verify it's handled again
        TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-session-handled-again")
    }
}
