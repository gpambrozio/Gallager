import Foundation

/// E2E scenario: Stop hook with last assistant message summary
///
/// Builds on the Claude Sessions Show scenario. Verifies that:
/// 1. After a Stop hook with `last_assistant_message`, the iOS session list shows "Session Idle"
/// 2. The iOS terminal view shows the StopResponseView with a collapsible summary
/// 3. The macOS Panes window shows the session in the sidebar
public enum StopHookSummaryScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Stop Hook Summary",
        tags: ["hooks", "sessions"]
    ) {
        // 1. Start with the Claude Sessions Show scenario
        //    (fresh pairing + 2 tmux sessions + SessionStart hook on pane 1)
        ClaudeSessionsShowScenario.scenario

        // 2. Send a Stop hook with last_assistant_message
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "e2e-test-session-1",
                "timestamp": "2026-02-14T10:01:00.000000Z",
                "last_assistant_message": "I've completed the refactoring of the authentication module. The changes include updating the JWT validation logic and adding refresh token support."
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )
        TestStep.wait(seconds: 3)

        // 3. Verify iOS session list shows "Session Idle" for the stop event
        TestStep.iosWaitForElement(.labelContains("Session Idle"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-session-idle")

        // 4. Tap the session to open the terminal view
        TestStep.iosTap(.labelContains("MyProject"))
        TestStep.wait(seconds: 5)

        // 5. Verify the StopResponseView shows the collapsed summary header (text hidden)
        TestStep.iosWaitForElement(.labelContains("Expand summary"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-stop-summary-collapsed")

        // 6. Tap the expand button to expand the summary
        TestStep.iosTap(.labelContains("Expand summary"))
        TestStep.wait(seconds: 1)

        // 7. Verify expanded state shows the full summary text
        TestStep.iosWaitForElement(.labelContains("refactoring of the authentication"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("adding refresh token support"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-stop-summary-expanded")

        // 8. Verify the prompt input is also present below the summary
        TestStep.iosWaitForElement(.labelContains("Send a message to Claude"), timeout: 5)

        // 9. Navigate back to session list
        TestStep.iosTap(.labelContains("Sessions"))
        TestStep.wait(seconds: 2)

        // 10. Verify macOS Panes window shows the session in the sidebar
        //     Note: The sidebar subtitle text (lastAssistantMessage) is not
        //     individually exposed in the macOS accessibility tree (NSOutlineView
        //     rows merge child text elements), so we verify the session entry
        //     exists and rely on the screenshot for visual verification of the summary.
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "session-1:0.0", timeout: 5)
        TestStep.macScreenshot(label: "mac-stop-session")
    }
}
