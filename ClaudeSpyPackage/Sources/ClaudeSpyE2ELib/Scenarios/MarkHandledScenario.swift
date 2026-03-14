import Foundation

/// E2E scenario: Session state sync across host and multiple viewers
///
/// Verifies that session status (Attention/Working/Idle) is correctly displayed
/// and synchronized across all three platforms:
/// 1. SessionStart triggers "Attention" on host, iOS viewer, and Mac viewer
/// 2. iOS viewer marks handled → state becomes "Idle" on all platforms
/// 3. PreToolUse transitions to "Working" on all platforms
/// 4. Stop event transitions to "Attention" on all platforms (triggers notification)
/// 5. Mac viewer selects session → marks handled → "Idle" on all platforms
/// 6. PermissionRequest re-raises "Attention" on all platforms
/// 7. Host selection marks handled → clears on all platforms
public enum MarkHandledScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Mark Handled",
        tags: ["hooks", "sessions", "sync"]
    ) {
        // ── Phase 1: Setup — pair host with iOS viewer and Mac viewer ─────

        FreshPairingScenario.scenario

        // Pair a second viewer (Mac instance 1)
        TestStep.log("Generating second pairing code for Mac viewer")
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Add Viewer")
        TestStep.wait(seconds: 3)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "viewerPairingCode")

        TestStep.log("Launching Mac viewer (instance 1)")
        TestStep.launchMacApp(instance: 1)
        TestStep.wait(seconds: 3)

        TestStep.macOpenSettings(instance: 1)
        TestStep.macWaitForWindow(titled: "General", timeout: 5, instance: 1)
        TestStep.macSelectSettingsTab("Remote Hosts", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Add Host", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macFocusElement(titled: "Pairing Code", instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "${viewerPairingCode}", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 5)

        TestStep.macWaitForElement(titled: "Connected", timeout: 15, instance: 1)

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

        // ── Phase 4: iOS marks handled by tapping session ─────────────────
        //
        // Opening the session on iOS marks it as handled.
        // SessionStart is not "working", so after handling → "Idle"

        TestStep.log("iOS tapping session to mark as handled")
        TestStep.iosTap(.labelContains("StateProject"))
        TestStep.wait(seconds: 3)

        // Go back to session list to see updated indicator
        TestStep.iosTap(.label("Sessions"))
        TestStep.wait(seconds: 2)

        // All platforms should now show "Idle" (SessionStart → not working)
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

        // ── Phase 7: Mac viewer selects session → marks handled → "Idle" ──
        //
        // Clicking the session on Mac viewer clears attention.
        // Stop event has isWorking = false, so after handling → "Idle"

        TestStep.log("Mac viewer selecting session to mark as handled")
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

        // ── Phase 9: Host selects session → marks handled ─────────────────
        //
        // Host clicks the window in the sidebar → marks handled.
        // PermissionRequest has isWorking = false → "Idle"

        TestStep.log("Host selecting session to mark as handled")
        TestStep.macClickButton(titled: "e2e-state:0")
        TestStep.wait(seconds: 3)

        // All platforms should show "Idle"
        TestStep.macWaitForElement(titled: "Idle", timeout: 10)
        TestStep.macScreenshot(label: "host-idle-final")

        TestStep.macWaitForElement(titled: "Idle", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-idle-final", instance: 1)

        TestStep.iosWaitForElement(.valueContains("Idle"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-idle-final")
    }
}
