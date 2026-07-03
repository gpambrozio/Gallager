import Foundation

/// E2E scenario: the iOS badge clears when attention is cleared by the AGENT
/// FLOW — not by the user viewing or explicitly handling the session.
///
/// Regression test for the "stuck badge" bug. The badge was raised by every
/// needs-attention notification's alert push, but only *lowered* on two paths:
/// viewing on the Mac (gated on `NSApp.isActive`) and the iOS `MarkHandled`
/// command. When attention cleared because the agent itself moved on — a
/// working hook (`UserPromptSubmit`) arriving after a `Stop`, or a
/// needs-attention session *ending* — `AppCoordinator.handlePluginState` and
/// the `.sessionEnded` app-action path only pushed WebSocket state to connected
/// viewers and never a badge push. A backgrounded/disconnected phone therefore
/// kept a stale badge.
///
/// The fix broadcasts a silent badge-decrement push whenever the host's
/// pending-attention count drops (`MirrorWindowManager.pendingCountDecrease` +
/// `AppCoordinator.broadcastBadgeDecreaseIfNeeded`). Unlike
/// `BadgeAggregationScenario` — which injects the decrement push directly into
/// the relay to exercise its aggregation math — this scenario drives the REAL
/// host clear paths via hook events and asserts the silent push actually goes
/// out over APNs. Without the fix, the Phase 5 and Phase 7 push waits time out.
///
/// As in `BadgeAggregationScenario`, the iOS WebSocket is blocked so every push
/// flows through the relay's APNs path (the relay skips APNs while the viewer
/// is connected), and the Panes window stays closed so
/// `markSelectedSessionsHandledIfActive` can't clear `needsAttention` before
/// the broadcast reads `pendingSessionCount`.
public enum BadgeClearsOnAgentResumeScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Badge Clears On Agent Resume",
        tags: ["push", "badge", "apns", "hooks"]
    ) {
        // ── Phase 1: Standard pairing (Mac0 + iOS) ─────────────────────────
        FreshPairingScenario.scenario

        // ── Phase 2: Force every push through the relay's APNs path ─────────
        // `sendEncryptedNotificationIfNeeded` is a no-op while the viewer's
        // WebSocket is connected, so block the viewer for the badge phases.
        TestStep.serverBlockDevice(.viewer)
        TestStep.wait(seconds: 2)

        // ── Phase 3: tmux session + a live agent session (Panes window stays
        //    closed so SwiftUI's auto-handle can't race the broadcast) ───────
        TestStep.tmuxCreateSession(name: "e2e-badge-clear", width: 80, height: 24)
        TestStep.wait(seconds: 3)
        TestStep.tmuxStorePaneId(target: "e2e-badge-clear:0.0", storeAs: "paneId")

        // SessionStart puts the pane into a working agent session (no attention,
        // no notification → no push).
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-badge-clear-session",
                "timestamp": "2026-02-14T10:00:00.000000Z",
                "source": "startup"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/BadgeClearProject"
        )
        TestStep.wait(seconds: 2)

        // The pairing handshake leaves noise in the relay's push log; reset it
        // so the phase-by-phase assertions only see badge-test entries.
        TestStep.clearAPNSPushLog

        // ── Phase 4: Stop → needs attention → alert push, badge = 1 ─────────
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "e2e-badge-clear-session",
                "timestamp": "2026-02-14T10:01:00.000000Z",
                "stop_hook_active": true,
                "last_assistant_message": "Task complete"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/BadgeClearProject"
        )
        TestStep.waitForAPNSPushCount(1, timeout: 15)
        TestStep.verifyLastAPNSPush(aggregatedBadge: 1, silent: false, pushType: "alert")

        // ── Phase 5: THE FIX — the agent resumes on its own (UserPromptSubmit
        //    → working) clears attention with no notification → silent
        //    badge-decrement push, badge = 0 ─────────────────────────────────
        // Before the fix this clear flowed through `handlePluginState`, which
        // only pushed WebSocket state — never an APNs push — so this wait would
        // time out and the badge would stay stuck at 1.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-badge-clear-session",
                "timestamp": "2026-02-14T10:02:00.000000Z",
                "prompt": "continue"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/BadgeClearProject"
        )
        TestStep.waitForAPNSPushCount(2, timeout: 15)
        TestStep.verifyLastAPNSPush(aggregatedBadge: 0, silent: true, pushType: "background")

        // ── Phase 6: Re-raise attention (Stop) → alert push, badge = 1 ──────
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "e2e-badge-clear-session",
                "timestamp": "2026-02-14T10:03:00.000000Z",
                "stop_hook_active": true,
                "last_assistant_message": "Task complete"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/BadgeClearProject"
        )
        TestStep.waitForAPNSPushCount(3, timeout: 15)
        TestStep.verifyLastAPNSPush(aggregatedBadge: 1, silent: false, pushType: "alert")

        // ── Phase 7: THE FIX (.sessionEnded path) — a needs-attention session
        //    that ENDS lowers the count with no notification → silent
        //    badge-decrement push, badge = 0 ─────────────────────────────────
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionEnd",
                "session_id": "e2e-badge-clear-session",
                "timestamp": "2026-02-14T10:04:00.000000Z",
                "reason": "user_quit"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/BadgeClearProject"
        )
        TestStep.waitForAPNSPushCount(4, timeout: 15)
        TestStep.verifyLastAPNSPush(aggregatedBadge: 0, silent: true, pushType: "background")

        // Restore iOS connectivity so later scenarios in the same run start
        // from a clean WebSocket state.
        TestStep.serverUnblockDevice(.viewer)
    }
}
