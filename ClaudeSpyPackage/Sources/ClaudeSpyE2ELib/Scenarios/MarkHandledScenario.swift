import Foundation

/// E2E scenario: Session state sync across host and multiple viewers
///
/// Verifies that session status (Idle/Working/Done/Permission) is correctly
/// displayed and synchronized across all three platforms, and that the
/// "viewed → idle" transition (`markHandled`) only clears a finished session:
/// 1. SessionStart settles to "Idle" on host, iOS viewer, and Mac viewer
/// 2. iOS viewer opens the idle session → markHandled is a no-op → stays "Idle"
/// 3. UserPromptSubmit transitions to "Working" on all platforms
/// 4. Stop event transitions to "Done" (doneWorking, needs attention) on all
/// 5. Mac viewer selects session → doneWorking IS clearable → "Idle"
/// 6. PermissionRequest opens the "Permission" form on all platforms
/// 7. iOS taps session → an awaiting* form is NOT clearable → "Permission" persists
/// 8. A subsequent working event (UserPromptSubmit) naturally moves to "Working"
public enum MarkHandledScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Mark Handled",
        tags: ["hooks", "sessions", "sync"]
    ) {
        // ── Phase 1: Setup — pair host with iOS viewer and Mac viewer ─────

        FreshPairingScenario.scenario

        // Pair a second viewer (Mac instance 1)
        Shortcut.addMacViewer

        // ── Phase 2: Create session and send SessionStart ─────────────────

        TestStep.tmuxCreateSession(name: "e2e-state", width: 80, height: 24)
        TestStep.wait(seconds: 3)
        TestStep.tmuxStorePaneId(target: "e2e-state:0.0", storeAs: "paneId")

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-state-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/StateProject"
        )
        TestStep.wait(seconds: 3)

        // Open panes windows on host and viewer
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "e2e-state", timeout: 10)

        Shortcut.openPanesWindow(instance: 1)
        TestStep.macWaitForElement(titled: "StateProject", timeout: 30, instance: 1)

        // ── Phase 3: Verify "Idle" on all three platforms ─────────────────
        //
        // SessionStart settles to `.idle` (the "session started" push still fires,
        // but a just-started session no longer needs attention).

        TestStep.log("Verifying Idle state on all platforms")

        // Host sidebar: accessibilityValue includes session status
        TestStep.macWaitForElement(titled: "Idle", timeout: 10)
        TestStep.macScreenshot(label: "host-idle-after-start")

        // Mac viewer sidebar
        TestStep.macWaitForElement(titled: "Idle", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-idle-after-start", instance: 1)

        // iOS: accessibilityValue on the session row
        TestStep.iosWaitForElement(.valueContains("Idle"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-idle-after-start")

        // ── Phase 4: iOS opens an idle session → markHandled is a no-op ───
        //
        // Opening a session only clears a `doneWorking` state. An idle session has
        // no attention to clear, so viewing it leaves it "Idle".

        TestStep.log("iOS opening idle session (markHandled is a no-op on idle)")
        TestStep.iosTap(.labelContains("StateProject"))
        TestStep.wait(seconds: 3)

        // Go back to session list to see the indicator
        TestStep.iosTap(.label("Sessions"))

        // All platforms still show "Idle"
        TestStep.iosWaitForElement(.valueContains("Idle"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-idle-after-view")

        TestStep.macWaitForElement(titled: "Idle", timeout: 10)
        TestStep.macScreenshot(label: "host-idle-after-ios-view")

        TestStep.macWaitForElement(titled: "Idle", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-idle-after-ios-view", instance: 1)

        // ── Phase 5: UserPromptSubmit transitions to "Working" ─────────────

        TestStep.log("Sending UserPromptSubmit event — transitions to Working")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-state-session",
                "timestamp": "2026-02-14T10:01:00.000000Z",
                "prompt": "do something"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/StateProject"
        )

        // All platforms show "Working" (UserPromptSubmit → isWorking = true)
        TestStep.iosWaitForElement(.valueContains("Working"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-working")

        TestStep.macWaitForElement(titled: "Working", timeout: 10)
        TestStep.macScreenshot(label: "host-working")

        TestStep.macWaitForElement(titled: "Working", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-working", instance: 1)

        // ── Phase 6: Stop event → "Done" (doneWorking, needs attention) ───

        TestStep.log("Sending Stop event — session becomes doneWorking (Done)")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "e2e-state-session",
                "timestamp": "2026-02-14T10:02:00.000000Z",
                "stop_hook_active": true,
                "last_assistant_message": "Task complete"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/StateProject"
        )

        // Stop → doneWorking → needsAttention = true → "Done"
        TestStep.iosWaitForElement(.valueContains("Done"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-done-after-stop")

        TestStep.macWaitForElement(titled: "Done", timeout: 10)
        TestStep.macScreenshot(label: "host-done-after-stop")

        TestStep.macWaitForElement(titled: "Done", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-done-after-stop", instance: 1)

        // ── Phase 7: Mac viewer selects session → doneWorking IS clearable ─
        //
        // Clicking the session on the Mac viewer clears attention. `doneWorking`
        // is the only state `markHandled` clears, so after handling → "Idle".

        TestStep.log("Mac viewer selecting session to mark as handled (Done is clearable)")
        TestStep.macClickButton(titled: "StateProject", instance: 1)

        // All platforms should now show "Idle"
        TestStep.macWaitForElement(titled: "Idle", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-idle-after-handle", instance: 1)

        TestStep.macWaitForElement(titled: "Idle", timeout: 10)
        TestStep.macScreenshot(label: "host-idle-after-viewer-handle")

        TestStep.iosWaitForElement(.valueContains("Idle"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-idle-after-viewer-handle")

        // ── Phase 8: PermissionRequest opens the "Permission" form ────────

        TestStep.log("Sending PermissionRequest — opens the Permission form")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-state-session",
                "timestamp": "2026-02-14T10:03:00.000000Z",
                "tool_name": "Write"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/StateProject"
        )

        // All platforms show "Permission"
        TestStep.iosWaitForElement(.valueContains("Permission"), timeout: 10)
        TestStep.macWaitForElement(titled: "Permission", timeout: 10)
        TestStep.macWaitForElement(titled: "Permission", timeout: 10, instance: 1)
        TestStep.iosScreenshot(label: "ios-permission")
        TestStep.macScreenshot(label: "host-permission")
        TestStep.macScreenshot(label: "viewer-permission", instance: 1)

        // ── Phase 9: iOS taps session → an awaiting* form is NOT clearable ─
        //
        // A permission requires an explicit answer (approve/deny). markHandled only
        // clears `doneWorking`, so an `awaitingPermission` state survives a view —
        // "Permission" must persist.

        TestStep.log("iOS tapping session — the Permission form should NOT be cleared")
        TestStep.iosTap(.labelContains("StateProject"))
        TestStep.wait(seconds: 3)

        // Go back to session list
        TestStep.iosTap(.label("Sessions"))

        // "Permission" should STILL be shown — the awaiting form was not cleared
        TestStep.iosWaitForElement(.valueContains("Permission"), timeout: 10)
        // Settle wait for the session-list back-navigation animation.
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-still-permission-after-view")

        TestStep.macWaitForElement(titled: "Permission", timeout: 10)
        TestStep.macScreenshot(label: "host-still-permission-after-view")

        TestStep.macWaitForElement(titled: "Permission", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-still-permission-after-view", instance: 1)

        // ── Phase 10: Host selects session → also NOT clearable ─────────
        //
        // Even the host selecting the session should not clear the awaiting form.

        TestStep.log("Host selecting session — Permission still NOT cleared")
        TestStep.macClickButton(titled: "e2e-state")

        TestStep.macWaitForElement(titled: "Permission", timeout: 10)
        TestStep.macScreenshot(label: "host-still-permission-after-host-select")

        TestStep.macWaitForElement(titled: "Permission", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-still-permission-after-host-select", instance: 1)

        TestStep.iosWaitForElement(.valueContains("Permission"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-still-permission-after-host-select")

        // ── Phase 11: Working event naturally clears attention ──────────
        //
        // A UserPromptSubmit event means the user sent a new prompt, which moves
        // the session to "Working" — naturally superseding the awaiting form.

        TestStep.log("Sending UserPromptSubmit — naturally moves from Permission to Working")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-state-session",
                "timestamp": "2026-02-14T10:04:00.000000Z",
                "prompt": "continue"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/StateProject"
        )

        // All platforms show "Working" — the awaiting form is gone
        TestStep.iosWaitForElement(.valueContains("Working"), timeout: 10)
        TestStep.macWaitForElement(titled: "Working", timeout: 10)
        TestStep.macWaitForElement(titled: "Working", timeout: 10, instance: 1)
        TestStep.iosScreenshot(label: "ios-working-after-permission")
        TestStep.macScreenshot(label: "host-working-final")
        TestStep.macScreenshot(label: "viewer-working-final", instance: 1)
    }
}
