import Foundation

/// E2E scenario: Yolo mode state synchronization between two Mac apps (host + viewer)
///
/// Verifies that yolo mode state syncs correctly between a macOS host and a macOS viewer:
/// 1. Host enables yolo mode -> viewer sees it reflected
/// 2. Viewer disables yolo mode -> host sees it reflected
/// 3. Viewer enables yolo mode -> host sees it reflected
/// 4. Host disables yolo mode -> viewer sees it reflected
public enum YoloModeMacToMacScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Yolo Mode Mac to Mac",
        tags: ["hooks", "sessions", "yolo", "macos-only"]
    ) {
        // ── Phase 1: Setup two Mac apps paired together ──────────────

        TwoMacPairingScenario.scenario

        // ── Phase 2: Send a SessionStart hook so pane becomes a Claude session ──

        TestStep.tmuxStorePaneId(target: "e2e-mac-pair:0.0", storeAs: "paneId")

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-mac-pair-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/MacPairProject"
        )

        // ── Phase 3: Verify both apps see the Claude session ─────────

        // Host should show the session
        TestStep.macWaitForElement(titled: "Enable yolo mode to auto-approve permissions", timeout: 10)

        // Viewer should see the yolo toggle for the remote Claude session
        TestStep.macWaitForElement(titled: "Enable yolo mode to auto-approve permissions", timeout: 10, instance: 1)

        // ── Phase 4: Host enables yolo mode -> verify viewer sees it ─

        TestStep.macClickButton(titled: "Enable yolo mode to auto-approve permissions")

        // Verify host shows enabled
        TestStep.macWaitForElement(
            titled: "Yolo mode: auto-approving permissions (click to disable)",
            timeout: 10
        )

        // Verify viewer also shows enabled
        TestStep.macWaitForElement(
            titled: "Yolo mode: auto-approving permissions (click to disable)",
            timeout: 10,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-yolo-enabled-from-host", instance: 1)

        // ── Phase 5: Viewer disables yolo mode -> verify host sees it ─

        TestStep.macClickButton(titled: "Yolo mode: auto-approving permissions (click to disable)", instance: 1)

        // Verify viewer shows disabled
        TestStep.macWaitForElement(
            titled: "Enable yolo mode to auto-approve permissions",
            timeout: 10,
            instance: 1
        )

        // Verify host also shows disabled
        TestStep.macWaitForElement(
            titled: "Enable yolo mode to auto-approve permissions",
            timeout: 10
        )
        TestStep.macScreenshot(label: "host-yolo-disabled-from-viewer")

        // ── Phase 6: Viewer enables yolo mode -> verify host sees it ─

        TestStep.macClickButton(titled: "Enable yolo mode to auto-approve permissions", instance: 1)

        // Verify viewer shows enabled
        TestStep.macWaitForElement(
            titled: "Yolo mode: auto-approving permissions (click to disable)",
            timeout: 10,
            instance: 1
        )

        // Verify host also shows enabled
        TestStep.macWaitForElement(
            titled: "Yolo mode: auto-approving permissions (click to disable)",
            timeout: 10
        )
        TestStep.macScreenshot(label: "host-yolo-enabled-from-viewer")

        // ── Phase 7: Host disables yolo mode -> verify viewer sees it ─

        TestStep.macClickButton(titled: "Yolo mode: auto-approving permissions (click to disable)")

        // Verify host shows disabled
        TestStep.macWaitForElement(
            titled: "Enable yolo mode to auto-approve permissions",
            timeout: 10
        )

        // Verify viewer also shows disabled
        TestStep.macWaitForElement(
            titled: "Enable yolo mode to auto-approve permissions",
            timeout: 10,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-yolo-disabled-from-host", instance: 1)
    }
}
