import Foundation

/// E2E scenario: APNs badge aggregation across two pairs sharing an iOS device.
///
/// Exercises the relay's `APNsService.lastBadge` aggregation logic — the same
/// iOS device paired with two Macs should see a single `aps.badge` value that
/// is the sum of each host's needs-attention contribution, rather than
/// last-write-wins.
///
/// Topology:
/// - Mac0 (real host) paired with iOS via the existing `FreshPairingScenario`.
/// - A *synthesized* second pair on the relay reuses iOS's real public key
///   and APNs push token (read via `serverReadFirstViewerIdentity`). No
///   second Mac host process runs — pushes for that pair are injected
///   directly into `APNsService` via `serverInjectPush`, which is sufficient
///   to exercise badge aggregation across siblings on the same device token.
///
/// To keep pushes flowing through the APNs code path (the relay skips APNs
/// when the iOS viewer's WebSocket is connected), iOS is blocked at the
/// connection hub for the duration of the badge phases.
///
/// Key ordering: the Stop hook is sent *before* the Panes window opens.
/// If the window is already open when the new session appears, SwiftUI's
/// auto-selection in `handleActiveSessionsChanged` fires
/// `markSelectedSessionsHandledIfActive`, which clears `needsAttention`
/// before the broadcast push reads `pendingSessionCount`. Keeping the
/// window closed during the attention phase pins `pendingSessionCount = 1`.
public enum BadgeAggregationScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Badge Aggregation",
        tags: ["push", "badge", "apns"]
    ) {
        // ── Phase 1: Standard pairing (Mac0 + iOS) ─────────────────────────
        FreshPairingScenario.scenario

        // Snapshot iOS's identity from the active pair. `viewerPairId` is
        // the pairId of the original Mac0↔iOS pair, used later to inject
        // Mac0's silent decrement push. The other fields seed the
        // synthesized second-host pair so both share one APNs token.
        TestStep.serverReadFirstViewerIdentity()

        // ── Phase 2: Synthesize a second pair for the same iOS device ──────
        //
        // After pairing, Remote Access exposes "Add Viewer" (Mac0 is already
        // paired so "Generate Pairing Code" isn't shown). The button still
        // calls `registerCode` server-side, so we grab the code and have the
        // server complete the pairing as iOS would, reusing iOS's identity
        // and synthetic push token.
        TestStep.macClickButton(titled: "Add Viewer")
        TestStep.wait(seconds: 3)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "mac1PairingCode")

        TestStep.serverCompletePairingAsViewer(
            codeKey: "mac1PairingCode",
            pushTokenKey: "viewerPushToken",
            viewerKeysPrefix: "viewer",
            storeAs: "mac1PairId"
        )
        TestStep.verifyServerHasPairings(count: 2)

        // ── Phase 3: Set up tmux session (no Panes window yet) ─────────────
        TestStep.tmuxCreateSession(name: "e2e-badge", width: 80, height: 24)
        TestStep.wait(seconds: 3)
        TestStep.tmuxStorePaneId(target: "e2e-badge:0.0", storeAs: "paneId")

        // Block the iOS WebSocket so the relay's APNs path runs for every
        // outgoing push — otherwise `sendEncryptedNotificationIfNeeded` is a
        // no-op while the viewer is connected.
        TestStep.serverBlockDevice(.viewer)
        TestStep.wait(seconds: 2)

        // The relay's push log accumulates noise from the pairing handshake.
        // Reset it so phase-by-phase assertions only see badge-test entries.
        TestStep.clearAPNSPushLog

        // ── Phase 4: Mac0 fires an attention push → aggregated = 1 ─────────
        //
        // Stop is a clearable event that sets needsAttention=true on Mac0,
        // so its broadcast carries `payload.badge = 1`. The Panes window is
        // intentionally still closed: with no `selectedWindow`, SwiftUI's
        // auto-handle in MainView won't race the broadcast and pin the count
        // back to zero.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "e2e-badge-session",
                "timestamp": "2026-02-14T10:01:00.000000Z",
                "stop_hook_active": true
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/BadgeProject"
        )

        TestStep.waitForAPNSPushCount(1, timeout: 15)
        TestStep.verifyLastAPNSPush(aggregatedBadge: 1, silent: false, pushType: "alert")

        // ── Phase 5: Mac1's first push raises aggregated badge to 2 ────────
        TestStep.serverInjectPush(pairIdKey: "mac1PairId", hostBadge: 1, silent: false)
        TestStep.waitForAPNSPushCount(2, timeout: 5)
        TestStep.verifyLastAPNSPush(aggregatedBadge: 2, silent: false, pushType: "alert")

        // ── Phase 6: Mac1's second push (badge=2) → aggregated = 3 ─────────
        TestStep.serverInjectPush(pairIdKey: "mac1PairId", hostBadge: 2, silent: false)
        TestStep.waitForAPNSPushCount(3, timeout: 5)
        TestStep.verifyLastAPNSPush(aggregatedBadge: 3, silent: false, pushType: "alert")

        // ── Phase 7: Mac0 clears its session → silent push, aggregated = 2 ─
        //
        // The real broadcast (selecting the session row → `markSessionHandled`
        // → `broadcastBadgeUpdate`) is gated on `NSApp.isActive`, which the
        // orchestrator cannot reliably set under accessibility-driven E2E.
        // MarkHandledScenario sidesteps this by routing every clear through a
        // remote `MarkHandled` command rather than the host click. For badge
        // aggregation we inject directly into the same APNs code path the
        // real broadcast funnels through — `sendEncryptedNotificationIfNeeded`
        // — so the relay's `lastBadge` decrement is exercised identically.
        TestStep.serverInjectPush(pairIdKey: "viewerPairId", hostBadge: 0, silent: true)
        TestStep.waitForAPNSPushCount(4, timeout: 5)
        TestStep.verifyLastAPNSPush(aggregatedBadge: 2, silent: true, pushType: "background")

        // ── Phase 8: Mac1 clears one session → aggregated = 1 ──────────────
        TestStep.serverInjectPush(pairIdKey: "mac1PairId", hostBadge: 1, silent: true)
        TestStep.waitForAPNSPushCount(5, timeout: 5)
        TestStep.verifyLastAPNSPush(aggregatedBadge: 1, silent: true, pushType: "background")

        // ── Phase 9: Mac1 clears the last session → aggregated = 0 ─────────
        TestStep.serverInjectPush(pairIdKey: "mac1PairId", hostBadge: 0, silent: true)
        TestStep.waitForAPNSPushCount(6, timeout: 5)
        TestStep.verifyLastAPNSPush(aggregatedBadge: 0, silent: true, pushType: "background")

        // Restore iOS connectivity so subsequent scenarios in the same run
        // start from a clean WebSocket state.
        TestStep.serverUnblockDevice(.viewer)
    }
}
