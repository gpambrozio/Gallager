import Foundation

/// E2E scenario: answering a permission request from a push notification's
/// action buttons, without ever opening the session (issue #710).
///
/// The notification banner itself renders in SpringBoard — out of the
/// harness's reach — so the `iosNotificationAction` step simulates the action
/// tap through the app's real `NotificationActionService.performAction` path,
/// using the action context that ACTUALLY arrived over the encrypted
/// live-socket notification. Everything else is the production pipeline:
/// Mac bakes the `NotificationActionContext` from the `awaitingPermission`
/// state, iOS plans the tap and submits `agentResponseSubmission`, the host
/// gate checks the open form, and the core delivers the keystroke. A
/// keystroke logger in the pane proves exactly which key landed:
///
/// - **Yes** on a suggestion-less permission → plain accept (`1`)
/// - **Always** on a permission carrying a suggestion → "Accept with Rule"
///   (`2`) — proving the suggestion id survived the notification round-trip
/// - A **stale** tap after the form was retracted (the agent moved on) →
///   dropped by the host's `AgentResponseSubmissionGuard`; nothing lands
public enum NotificationActionScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Notification Action Buttons",
        tags: ["hooks", "permission", "notifications", "response"]
    ) {
        // Setup: paired session on pane 1 ("MyProject"), plus the keystroke logger.
        ClaudeSessionsShowScenario.scenario
        TestStep.injectScript(name: "keystroke_logger.py")

        // ── Phase 1: suggestion-less permission → "Yes" action → accept (1) ─────
        // Start the logger first so it's reading stdin when the keystroke
        // arrives, then raise the permission. The iOS app stays on the session
        // list the whole time — the answer comes from the notification.
        Shortcut.tmuxRunCommand(
            target: "session-1:0",
            command: "python3 $TMPDIR/keystroke_logger.py"
        )
        TestStep.tmuxWaitForPaneContent(target: "session-1:0", contains: "LOGGER_READY")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-test-session-1",
                "tool_name": "Bash",
                "tool_input": {
                    "command": "rm -rf build",
                    "description": "Clean the build folder"
                }
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )
        // The app waits internally for the actionable notification to arrive.
        TestStep.iosNotificationAction(actionIdentifier: "gallager.permission.allow")
        // tolerance 2: absorbs the Dynamic Island's black/invisible rendering
        // flip in simulator captures plus the row spinner (SessionStateSorting
        // precedent for session-list screenshots).
        TestStep.iosScreenshot(label: "ios-list-during-allow", tolerance: 2)
        TestStep.wait(seconds: 6)
        TestStep.tmuxCapturePaneContent(target: "session-1:0", storeAs: "allowSeq")
        // Plain accept = option 1.
        TestStep.assertStoredContains(key: "allowSeq", substring: "SEQUENCE: T<1>")

        // ── Phase 2: permission WITH a suggestion → "Always" → accept-with-rule (2)
        // `clear` + a phase-unique marker: waiting for the marker first proves
        // the screen was wiped (phase 1's leftover LOGGER_READY is gone), so
        // the LOGGER_READY wait can only match THIS phase's logger — a fixed
        // sleep would drop the keystroke on a loaded runner with slow python
        // startup.
        Shortcut.tmuxRunCommand(
            target: "session-1:0",
            command: "clear && echo PHASE2START && python3 $TMPDIR/keystroke_logger.py"
        )
        TestStep.tmuxWaitForPaneContent(target: "session-1:0", contains: "PHASE2START")
        TestStep.tmuxWaitForPaneContent(target: "session-1:0", contains: "LOGGER_READY")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-test-session-1",
                "tool_name": "Bash",
                "tool_input": {
                    "command": "npm install",
                    "description": "Install dependencies"
                },
                "permission_suggestions": [
                    {
                        "type": "addRules",
                        "destination": "session",
                        "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}]
                    }
                ]
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )
        TestStep.iosNotificationAction(actionIdentifier: "gallager.permission.always")
        TestStep.wait(seconds: 6)
        TestStep.tmuxCapturePaneContent(target: "session-1:0", storeAs: "alwaysSeq")
        // "Always" applies the suggestion = the "Accept with Rule" option (2).
        TestStep.assertStoredContains(key: "alwaysSeq", substring: "SEQUENCE: T<2>")

        // ── Phase 3: stale tap after the form is retracted → guard drops it ─────
        // The user answered in the terminal and the agent moved on (working).
        // The notification is still on the lock screen; tapping it now must
        // deliver NOTHING to the pane.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-test-session-1",
                "prompt": "continue"
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )
        // Fresh screen + fresh logger so the assertion sees only this phase
        // (same marker-then-ready wait pattern as phase 2).
        Shortcut.tmuxRunCommand(
            target: "session-1:0",
            command: "clear && echo PHASE3START && python3 $TMPDIR/keystroke_logger.py"
        )
        TestStep.tmuxWaitForPaneContent(target: "session-1:0", contains: "PHASE3START")
        TestStep.tmuxWaitForPaneContent(target: "session-1:0", contains: "LOGGER_READY")
        // Re-tap the already-consumed phase-2 notification: iOS submits (the
        // tap "succeeds" client-side); the HOST drops it because the pane's
        // open form no longer matches the request id.
        TestStep.iosNotificationAction(actionIdentifier: "gallager.permission.allow", reuseLast: true)
        TestStep.wait(seconds: 6)
        TestStep.tmuxCapturePaneContent(target: "session-1:0", storeAs: "staleSeq")
        // Logger ran and idled out...
        TestStep.assertStoredContains(key: "staleSeq", substring: "SEQUENCE:")
        // ...but no keystroke was delivered (no text, no escape).
        TestStep.assertStoredNotContains(key: "staleSeq", substring: "T<")
        TestStep.assertStoredNotContains(key: "staleSeq", substring: "ESC")
        TestStep.iosScreenshot(label: "ios-list-working-after-retract", tolerance: 2)
    }
}
