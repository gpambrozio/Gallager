import Foundation

/// E2E scenario: a connected Mac viewer materializes host agent notifications
///
/// Regression coverage for issue #628 — a Mac acting as a *viewer* of a remote
/// host should surface the same notifications a paired iOS device does. The
/// host pushes a pre-baked notification over the live WebSocket whenever one of
/// its sessions needs attention; a connected Mac viewer posts it as a local
/// desktop notification (previously only iOS viewers did).
///
/// Flow:
/// 1. Pair two Mac apps (host = instance 0, viewer = instance 1, both connected)
/// 2. Create a tmux session on the host and mark it a Claude session
/// 3. Send a Bash `PermissionRequest` to the host — needs attention → notify
/// 4. Assert the *viewer's* notification log recorded the alert, proving it
///    materialized the host-pushed notification locally
public enum MacViewerNotificationScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Mac Viewer Notification",
        tags: ["notifications", "sessions", "macos-only"]
    ) {
        // ── Setup: pair two Mac apps (host + viewer, both connected) ──
        Shortcut.twoMacPairing

        // ── Create a tmux session on the host and capture its pane id ──
        TestStep.tmuxCreateSession(name: "notif-mac", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "notif-mac:0.0", storeAs: "paneId")
        TestStep.wait(seconds: 2)

        // Mark the pane a Claude session so the permission event attaches to it.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-mac-viewer-notif",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/NotifProject"
        )
        TestStep.wait(seconds: 3)

        // ── Trigger a needs-attention event on the host ──
        // A Bash PermissionRequest (yolo mode off) makes the session need
        // attention, so the host bakes a "Permission: Bash" notification and
        // pushes it to every connected viewer over the live WebSocket.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-mac-viewer-notif",
                "timestamp": "2026-02-14T10:01:00.000000Z",
                "tool_name": "Bash",
                "tool_input": {
                    "command": "npm install",
                    "description": "Install dependencies"
                }
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/NotifProject"
        )

        // ── Assert the VIEWER materialized the notification locally ──
        // The e2eTest TerminalNotificationService appends `paneId|title|body|hostId`
        // to instance 1's log. Polling absorbs the WebSocket + file-write delay;
        // finding "Permission: Bash" there proves the viewer posted the alert the
        // host pushed to it — the behavior issue #628 asked for.
        TestStep.waitForFileContains(
            path: "${notificationLogPath1}",
            substring: "Permission: Bash",
            storeAs: "viewerNotificationLog",
            timeout: 15
        )
    }
}
