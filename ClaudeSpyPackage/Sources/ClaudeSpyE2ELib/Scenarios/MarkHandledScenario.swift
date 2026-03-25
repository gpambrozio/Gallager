import Foundation

/// E2E scenario: Session state sync across host and multiple viewers
///
/// Verifies that session status (Attention/Working/Idle) is correctly displayed
/// and synchronized across all three platforms:
/// 1. SessionStart triggers "Attention" on host, iOS viewer, and Mac viewer
/// 2. iOS viewer marks handled → state becomes "Idle" (SessionStart is clearable)
/// 3. PreToolUse transitions to "Working" on all platforms
/// 4. Stop event transitions to "Attention" on all platforms (triggers notification)
/// 5. Mac viewer selects session → marks handled → "Idle" (Stop is clearable)
/// 6. PermissionRequest re-raises "Attention" on all platforms
/// 7. iOS taps session → "Attention" persists (PermissionRequest is NOT clearable)
/// 8. A subsequent working event (PreToolUse) naturally moves to "Working"
/// 9. Host selection marks handled on non-attention state → stays at current state
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
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Available Windows", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macResizeWindow(width: 1_000, height: 600)
        TestStep.macSetSidebarWidth(250)
        TestStep.macWaitForElement(titled: "e2e-state:0", timeout: 10)

        TestStep.macOpenPanesWindow(instance: 1)
        TestStep.macWaitForWindow(titled: "Available Windows", timeout: 5, instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macResizeWindow(width: 1_000, height: 600, instance: 1)
        TestStep.macSetSidebarWidth(250, instance: 1)
        TestStep.macWaitForElement(titled: "StateProject", timeout: 30, instance: 1)

        // ── Phase 3: Verify "Attention" on all three platforms ────────────
        //
        // SessionStart triggers a notification → needsAttention = true

        TestStep.log("Verifying Attention state on all platforms")

        // Host sidebar: accessibilityValue includes session status
        TestStep.macWaitForElement(titled: "Attention", timeout: 10)
        TestStep.macScreenshot(label: "host-attention")

        // Mac viewer sidebar
        TestStep.macWaitForElement(titled: "Attention", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-attention", instance: 1)

        // iOS: accessibilityValue on the session row
        TestStep.iosWaitForElement(.valueContains("Attention"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-attention")

        // ── Phase 4: iOS marks handled → SessionStart IS clearable → "Idle" ─
        //
        // Opening the session on iOS marks it as handled.
        // SessionStart is clearable, so after handling → "Idle"

        TestStep.log("iOS tapping session to mark as handled (SessionStart is clearable)")
        TestStep.iosTap(.labelContains("StateProject"))
        TestStep.wait(seconds: 3)

        // Go back to session list to see updated indicator
        TestStep.iosTap(.label("Sessions"))
        TestStep.wait(seconds: 2)

        // All platforms should now show "Idle" (SessionStart → not working, cleared)
        TestStep.iosWaitForElement(.valueContains("Idle"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-idle-after-handle")

        TestStep.macWaitForElement(titled: "Idle", timeout: 10)
        TestStep.macScreenshot(label: "host-idle-after-ios-handle")

        TestStep.macWaitForElement(titled: "Idle", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-idle-after-ios-handle", instance: 1)

        // ── Phase 5: PreToolUse transitions to "Working" ──────────────────

        TestStep.log("Sending PreToolUse event — transitions to Working")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PreToolUse",
                "session_id": "e2e-state-session",
                "timestamp": "2026-02-14T10:01:00.000000Z",
                "tool_name": "Edit"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/StateProject"
        )
        TestStep.wait(seconds: 3)

        // All platforms show "Working" (PreToolUse → isWorking = true)
        TestStep.iosWaitForElement(.valueContains("Working"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-working")

        TestStep.macWaitForElement(titled: "Working", timeout: 10)
        TestStep.macScreenshot(label: "host-working")

        TestStep.macWaitForElement(titled: "Working", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-working", instance: 1)

        // ── Phase 6: Stop event → "Attention" (stop triggers notification) ─

        TestStep.log("Sending Stop event — session becomes idle/attention")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "e2e-state-session",
                "timestamp": "2026-02-14T10:02:00.000000Z",
                "stop_hook_active": true
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/StateProject"
        )
        TestStep.wait(seconds: 3)

        // Stop triggers notification → needsAttention = true → "Attention"
        TestStep.iosWaitForElement(.valueContains("Attention"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-attention-after-stop")

        TestStep.macWaitForElement(titled: "Attention", timeout: 10)
        TestStep.macScreenshot(label: "host-attention-after-stop")

        TestStep.macWaitForElement(titled: "Attention", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-attention-after-stop", instance: 1)

        // ── Phase 7: Mac viewer selects session → Stop IS clearable → "Idle" ─
        //
        // Clicking the session on Mac viewer clears attention.
        // Stop event has isWorking = false, so after handling → "Idle"

        TestStep.log("Mac viewer selecting session to mark as handled (Stop is clearable)")
        TestStep.macClickButton(titled: "StateProject", instance: 1)
        TestStep.wait(seconds: 3)

        // All platforms should now show "Idle"
        TestStep.macWaitForElement(titled: "Idle", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-idle-after-handle", instance: 1)

        TestStep.macWaitForElement(titled: "Idle", timeout: 10)
        TestStep.macScreenshot(label: "host-idle-after-viewer-handle")

        TestStep.iosWaitForElement(.valueContains("Idle"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-idle-after-viewer-handle")

        // ── Phase 8: PermissionRequest re-raises "Attention" ──────────────

        TestStep.log("Sending PermissionRequest — re-raises attention")
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
        TestStep.wait(seconds: 3)

        // All platforms show "Attention" again
        TestStep.iosWaitForElement(.valueContains("Attention"), timeout: 10)
        TestStep.macWaitForElement(titled: "Attention", timeout: 10)
        TestStep.macWaitForElement(titled: "Attention", timeout: 10, instance: 1)
        TestStep.iosScreenshot(label: "ios-attention-permission")
        TestStep.macScreenshot(label: "host-attention-permission")
        TestStep.macScreenshot(label: "viewer-attention-permission", instance: 1)

        // ── Phase 9: iOS taps session → PermissionRequest is NOT clearable ─
        //
        // PermissionRequest requires explicit user action (approve/deny).
        // markHandled should NOT clear it — "Attention" must persist.

        TestStep.log("iOS tapping session — PermissionRequest should NOT be cleared")
        TestStep.iosTap(.labelContains("StateProject"))
        TestStep.wait(seconds: 3)

        // Go back to session list
        TestStep.iosTap(.label("Sessions"))
        TestStep.wait(seconds: 2)

        // Attention should STILL be shown — PermissionRequest was not cleared
        TestStep.iosWaitForElement(.valueContains("Attention"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-still-attention-after-permission-handle")

        TestStep.macWaitForElement(titled: "Attention", timeout: 10)
        TestStep.macScreenshot(label: "host-still-attention-after-permission-handle")

        TestStep.macWaitForElement(titled: "Attention", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-still-attention-after-permission-handle", instance: 1)

        // ── Phase 10: Host selects session → also NOT clearable ─────────
        //
        // Even the host selecting the session should not clear PermissionRequest.

        TestStep.log("Host selecting session — PermissionRequest still NOT cleared")
        TestStep.macClickButton(titled: "e2e-state:0")
        TestStep.wait(seconds: 3)

        TestStep.macWaitForElement(titled: "Attention", timeout: 10)
        TestStep.macScreenshot(label: "host-still-attention-after-host-select")

        TestStep.macWaitForElement(titled: "Attention", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-still-attention-after-host-select", instance: 1)

        TestStep.iosWaitForElement(.valueContains("Attention"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-still-attention-after-host-select")

        // ── Phase 11: Working event naturally clears attention ──────────
        //
        // A PreToolUse event means Claude is processing again, which moves
        // the session to "Working" — naturally superseding the attention state.

        TestStep.log("Sending PreToolUse — naturally moves from Attention to Working")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PreToolUse",
                "session_id": "e2e-state-session",
                "timestamp": "2026-02-14T10:04:00.000000Z",
                "tool_name": "Bash"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/StateProject"
        )
        TestStep.wait(seconds: 3)

        // All platforms show "Working" — attention is gone
        TestStep.iosWaitForElement(.valueContains("Working"), timeout: 10)
        TestStep.macWaitForElement(titled: "Working", timeout: 10)
        TestStep.macWaitForElement(titled: "Working", timeout: 10, instance: 1)
        TestStep.iosScreenshot(label: "ios-working-after-permission")
        TestStep.macScreenshot(label: "host-working-final")
        TestStep.macScreenshot(label: "viewer-working-final", instance: 1)
    }
}
