import Foundation

/// E2E scenario: the sidebar (macOS host) and the session list (iOS viewer)
/// re-sort live when a session's displayed state changes — via the agent's own
/// state AND via the manual "Set State" override, on agent sessions and
/// terminal-only sessions alike (issue #702 follow-on).
///
/// Both sides run the default `statusPriorityIdleFirst` mode (attention >
/// idle > working > plain terminal, session-name tiebreak): the host sorts
/// with it directly, and iOS mirrors it via the `sidebarSortMode` the host
/// pushes with its session state, applied through the shared
/// `SessionSortData.sortedRemoteSessions`.
///
/// Fixture: two idle agent sessions ("alpha-agent" → AlphaProject,
/// "beta-agent" → BetaProject) and one plain terminal session ("zed-term").
/// Baseline order: [Alpha, Beta, zed].
///
/// Phases (expected order after each, asserted by mac + iOS screenshots,
/// synced on row-specific iOS accessibility values so the host-apply → push →
/// viewer-render chain completed before each capture):
///   1. `Stop` hook on beta → needs attention → [Beta, Alpha, zed]
///      (the agent's own state re-sorts, no pin involved).
///   2. Pin beta → Idle → the bell is suppressed and beta falls back →
///      [Alpha, Beta, zed] (manual override re-sorts downward).
///   3. Pin zed-term → Waiting for input → the TERMINAL session rises over
///      idle agents → [zed, Alpha, Beta] (the flagship new behavior: pinned
///      terminal-only sessions sort — and badge — like any bell).
///   4. Pin alpha → Waiting for input → two waiting rows, name tiebreak →
///      [Alpha, zed, Beta].
///   5. Clear zed via "Automatic" → back to the plain-terminal bucket →
///      [Alpha, Beta, zed] (alpha still pinned waiting, beta still pinned
///      idle).
///
/// The menu bar dropdown shares this exact ordering by construction
/// (`SessionSortData.sortedLocalSessions` — unit-covered; the system menu
/// isn't screenshot-able by the harness). iOS-initiated pins are covered by
/// `SessionStateMenuScenario`; this scenario drives all pins from the host
/// and treats iOS as the mirror under test.
public enum SessionStateSortingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Session State Sorting",
        tags: ["state", "sorting", "sync"]
    ) {
        // ── Setup: pair, then three sessions — two agents + one terminal ──

        FreshPairingScenario.scenario

        TestStep.tmuxCreateSession(name: "alpha-agent", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "beta-agent", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "zed-term", width: 80, height: 24)
        TestStep.wait(seconds: 2)

        TestStep.tmuxStorePaneId(target: "alpha-agent:0.0", storeAs: "alphaPaneId")
        TestStep.tmuxStorePaneId(target: "beta-agent:0.0", storeAs: "betaPaneId")

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-sort-alpha",
                "timestamp": "2026-08-01T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${alphaPaneId}",
            projectPath: "/Users/test/AlphaProject"
        )
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-sort-beta",
                "timestamp": "2026-08-01T10:00:01.000000Z"
            }
            """,
            tmuxPane: "${betaPaneId}",
            projectPath: "/Users/test/BetaProject"
        )

        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "AlphaProject", timeout: 30)
        TestStep.macWaitForElement(titled: "BetaProject", timeout: 15)
        TestStep.macWaitForElement(titled: "zed-term", timeout: 15)
        // Terminal streams can auto-grow the panes window after sessions are
        // created — re-pin the size so every screenshot shares one geometry.
        TestStep.macResizeWindow(width: 1_000, height: 600)

        TestStep.iosWaitForElement(.labelContains("AlphaProject"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("BetaProject"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("zed-term"), timeout: 15)

        // Baseline order: [Alpha, Beta, zed] — idle agents by name, terminal last.
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-sort-baseline")
        TestStep.iosScreenshot(label: "ios-sort-baseline", tolerance: 2)

        // ── Phase 1: beta's OWN state change re-sorts (no pin) ────────────

        TestStep.log("Stop hook on beta-agent — attention rises to the top on both platforms")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "e2e-sort-beta",
                "timestamp": "2026-08-01T10:01:00.000000Z",
                "stop_hook_active": true,
                "last_assistant_message": "Task complete"
            }
            """,
            tmuxPane: "${betaPaneId}",
            projectPath: "/Users/test/BetaProject"
        )
        TestStep.iosWaitForElement(
            .allOf([.labelContains("BetaProject"), .valueContains("Done")]),
            timeout: 20
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-sort-beta-attention-first")
        TestStep.iosScreenshot(label: "ios-sort-beta-attention-first", tolerance: 2)

        // ── Phase 2: pin beta → Idle — suppression re-sorts downward ──────

        TestStep.log("Pinning beta-agent → Idle: the bell is suppressed and beta falls back below alpha")
        TestStep.macContextSubmenuClick(
            elementTitle: "beta-agent",
            parentMenuItem: "Set State",
            submenuItem: "Idle"
        )
        TestStep.iosWaitForElement(
            .allOf([.labelContains("BetaProject"), .valueContains("Idle")]),
            timeout: 20
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-sort-beta-pinned-idle")
        TestStep.iosScreenshot(label: "ios-sort-beta-pinned-idle", tolerance: 2)

        // ── Phase 3: pin the TERMINAL session → Waiting — it rises to top ─

        TestStep.log("Pinning zed-term → Waiting for input: the terminal session rises above idle agents")
        TestStep.macContextSubmenuClick(
            elementTitle: "zed-term",
            parentMenuItem: "Set State",
            submenuItem: "Waiting for input"
        )
        TestStep.iosWaitForElement(
            .allOf([.labelContains("zed-term"), .valueContains("Waiting for input")]),
            timeout: 20
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-sort-terminal-pinned-waiting")
        TestStep.iosScreenshot(label: "ios-sort-terminal-pinned-waiting", tolerance: 2)

        // ── Phase 4: pin alpha → Waiting — name tiebreak inside the bucket ─

        TestStep.log("Pinning alpha-agent → Waiting for input: two waiting rows, alpha wins the name tiebreak")
        TestStep.macContextSubmenuClick(
            elementTitle: "alpha-agent",
            parentMenuItem: "Set State",
            submenuItem: "Waiting for input"
        )
        TestStep.iosWaitForElement(
            .allOf([.labelContains("AlphaProject"), .valueContains("Waiting for input")]),
            timeout: 20
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-sort-alpha-pinned-waiting")
        TestStep.iosScreenshot(label: "ios-sort-alpha-pinned-waiting", tolerance: 2)

        // ── Phase 5: clear zed via Automatic — back to the terminal bucket ─

        TestStep.log("Clearing zed-term via 'Automatic': the terminal drops back to the bottom")
        TestStep.macContextSubmenuClick(
            elementTitle: "zed-term",
            parentMenuItem: "Set State",
            submenuItem: "Automatic"
        )
        TestStep.iosWaitForElementToDisappear(
            .allOf([.labelContains("zed-term"), .valueContains("Waiting for input")]),
            timeout: 20
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-sort-terminal-cleared")
        TestStep.iosScreenshot(label: "ios-sort-terminal-cleared", tolerance: 2)
    }
}
