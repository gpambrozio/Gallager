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
                "last_assistant_message": "I've completed the refactoring of the authentication module. The changes include updating the JWT validation logic, adding refresh token support, and migrating the session store to use async/await patterns. All existing tests have been updated to reflect the new architecture and are passing successfully."
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )

        // 3. Verify iOS session list shows the stop state. In the agent-blind model
        //    a Stop sets the session to `doneWorking`, whose status label is "Done"
        //    (it still needs attention) — not a per-event "Session Idle" row.
        TestStep.iosWaitForElement(.labelContains("Done"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-session-idle")

        // 4. Tap the session to open the terminal view
        TestStep.iosTap(.labelContains("MyProject"))

        // 5. Verify the StopResponseView shows the collapsed summary with 2-line preview.
        //    Also wait for the "Send" toolbar button — it renders slightly after the
        //    summary content arrives, and the screenshot needs the toolbar fully
        //    settled (otherwise Send/menu icons appear washed out / mid-fade-in).
        TestStep.iosWaitForElement(.labelContains("Expand summary"), timeout: 10)
        TestStep.iosWaitForElement(.identifier("summary-text"), timeout: 5)
        TestStep.iosWaitForElement(.label("Send"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-stop-summary-collapsed")

        // 6. Tap the expand button to expand the summary
        TestStep.iosTap(.labelContains("Expand summary"))

        // 7. Verify expanded state shows the full summary text (including tail end).
        //    Wait briefly so the expand animation has time to settle before the
        //    screenshot is taken — otherwise text mid-transition can drift just
        //    past the screenshot tolerance.
        TestStep.iosWaitForElement(.labelContains("passing successfully"), timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-stop-summary-expanded")

        // 8. Verify the reply input is also present below the summary (the
        //    agent-blind reply-after-stop form's placeholder).
        TestStep.iosWaitForElement(.labelContains("Reply to the agent"), timeout: 5)

        // 9. Navigate back to session list
        TestStep.iosTap(.labelContains("Sessions"))

        // 10. Verify macOS Panes window shows the session in the sidebar
        //     Note: The sidebar subtitle text (lastAssistantMessage) is not
        //     individually exposed in the macOS accessibility tree (NSOutlineView
        //     rows merge child text elements), so we verify the session entry
        //     exists and rely on the screenshot for visual verification of the summary.
        //     Use Shortcut.openPanesWindow so the window is explicitly sized,
        //     making the screenshot dimensions deterministic instead of
        //     depending on whatever NSWindow autosave inherited from prior scenarios.
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "session-1", timeout: 5)
        TestStep.macScreenshot(label: "mac-stop-session")
    }
}
