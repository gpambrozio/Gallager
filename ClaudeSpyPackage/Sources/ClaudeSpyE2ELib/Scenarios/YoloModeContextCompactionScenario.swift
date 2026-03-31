import Foundation

/// E2E scenario: Yolo mode persists across context compaction (session restart)
///
/// Regression test for issue #193: context compaction sends a SessionStart
/// without a preceding SessionEnd, which used to reset yolo mode.
///
/// Verifies:
/// 1. Enable yolo mode on a Claude session
/// 2. Send a second SessionStart (simulating context compaction) — yolo stays on
/// 3. Send SessionEnd (normal exit) — yolo is cleared
/// 4. Start a new session — yolo is still cleared (not leaked from previous)
public enum YoloModeContextCompactionScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Yolo Mode Context Compaction",
        tags: ["hooks", "sessions", "yolo", "macos-only"]
    ) {
        // ── Setup: single Mac app with a tmux pane ──────────────

        TestStep.log("Setting up tmux session and Mac app")
        TestStep.tmuxCreateSession(name: "yolo-compact", width: 80, height: 24)

        Shortcut.macOnlySetup

        TestStep.tmuxStorePaneId(target: "yolo-compact:0", storeAs: "paneId")

        // ── Phase 1: Start a Claude session ─────────────────────

        TestStep.log("Phase 1: Start initial Claude session")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "yolo-compact-session-1",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/CompactionProject"
        )
        TestStep.wait(seconds: 3)

        // Select the pane in sidebar to see yolo button
        TestStep.macClickButton(titled: "yolo-compact")
        TestStep.wait(seconds: 1)

        // Verify yolo mode starts disabled
        TestStep.macWaitForElement(
            titled: "Enable yolo mode to auto-approve permissions",
            timeout: 10
        )

        // ── Phase 2: Enable yolo mode ───────────────────────────

        TestStep.log("Phase 2: Enable yolo mode")
        TestStep.macClickButton(titled: "Enable yolo mode to auto-approve permissions")
        TestStep.wait(seconds: 2)

        TestStep.macWaitForElement(
            titled: "Yolo mode: auto-approving permissions (click to disable)",
            timeout: 10
        )
        TestStep.macScreenshot(label: "yolo-enabled-before-compaction")

        // ── Phase 3: Simulate context compaction (SessionStart without SessionEnd) ──

        TestStep.log("Phase 3: Send SessionStart again (context compaction restart)")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "yolo-compact-session-1-restarted",
                "timestamp": "2026-02-14T10:01:00.000000Z"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/CompactionProject"
        )
        TestStep.wait(seconds: 3)

        // CRITICAL: Yolo mode must still be enabled after the restart
        TestStep.macWaitForElement(
            titled: "Yolo mode: auto-approving permissions (click to disable)",
            timeout: 10
        )
        TestStep.macScreenshot(label: "yolo-preserved-after-compaction")

        // ── Phase 4: Normal session end clears yolo ─────────────

        TestStep.log("Phase 4: SessionEnd should clear yolo mode")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionEnd",
                "session_id": "yolo-compact-session-1-restarted",
                "timestamp": "2026-02-14T10:02:00.000000Z",
                "reason": "user_quit"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/CompactionProject"
        )
        TestStep.wait(seconds: 3)

        // Session ended — pane moves back to Terminals
        TestStep.macWaitForElementToDisappear(titled: "Claude Sessions", timeout: 10)
        TestStep.macScreenshot(label: "session-ended-yolo-cleared")

        // ── Phase 5: New session starts without yolo leaked ─────

        TestStep.log("Phase 5: New session should start without yolo mode")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "yolo-compact-session-2",
                "timestamp": "2026-02-14T10:03:00.000000Z"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/CompactionProject"
        )
        TestStep.wait(seconds: 3)

        // Select the pane again
        TestStep.macClickButton(titled: "yolo-compact")
        TestStep.wait(seconds: 1)

        // Yolo mode should be disabled on the fresh session
        TestStep.macWaitForElement(
            titled: "Enable yolo mode to auto-approve permissions",
            timeout: 10
        )
        TestStep.macScreenshot(label: "new-session-yolo-off")
    }
}
