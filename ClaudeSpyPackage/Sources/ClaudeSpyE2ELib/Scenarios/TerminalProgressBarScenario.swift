import Foundation

/// E2E scenario: `OSC 9;4` per-pane terminal progress bar across all platforms.
///
/// Exercises the full pipeline added in PR #449:
/// 1. Host's `PipePaneReader` extracts an `OSC 9;4;<state>;<progress>` sequence
///    from the tmux pane's pipe-pane FIFO.
/// 2. `PaneStreamManager.onProgress` forwards it to `MirrorWindowManager.setPaneProgress`,
///    which writes it onto `PaneState.progress` (one source of truth).
/// 3. The host's local sidebar (`SessionSidebarRow`) reads from `paneStates` directly.
/// 4. Changed values trigger `pushSessionStateToAll`, which delivers the new
///    `PaneState.progress` to every connected viewer over the relay.
/// 5. The Mac viewer's `RemoteSessionSidebarRow` and the iOS `SessionListView.sessionRow`
///    both read `pane.progress` from the propagated state and render the same
///    `TerminalProgressBar` — host and viewers must agree.
///
/// The scenario uses one host (instance 0) + one Mac viewer (instance 1) + one
/// iOS viewer paired with the host. Indeterminate state (`3`) is intentionally
/// skipped because its `TimelineView`-driven scanner is non-deterministic
/// frame-to-frame and would make screenshot comparison flaky.
public enum TerminalProgressBarScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal Progress Bar",
        tags: ["terminal", "progress", "sync"]
    ) {
        // ── Phase 1: Pair host + iOS, then add a Mac viewer ──────────────

        FreshPairingScenario.scenario
        Shortcut.addMacViewer

        // ── Phase 2: Create tmux session and decorate it as a Claude session ─
        //
        // SessionStart with a fixed project path makes the row's display name
        // stable ("ProgressTest" everywhere) instead of leaking the machine's
        // home-folder basename into iOS/viewer rows. The fixed past timestamp
        // keeps the relative-time text deterministic across runs.

        TestStep.tmuxCreateSession(name: "e2e-progress", width: 80, height: 24)
        TestStep.wait(seconds: 2)
        TestStep.tmuxStorePaneId(target: "e2e-progress:0.0", storeAs: "paneId")

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-progress-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/ProgressTest"
        )
        TestStep.wait(seconds: 3)

        // ── Phase 3: Open Panes windows on host and Mac viewer ───────────

        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "ProgressTest", timeout: 15)

        Shortcut.openPanesWindow(instance: 1)
        TestStep.macWaitForElement(titled: "ProgressTest", timeout: 30, instance: 1)

        // iOS row appears once SessionStart propagates over the relay
        TestStep.iosWaitForElement(.labelContains("ProgressTest"), timeout: 30)

        // ── Phase 4: Wait for the host's OSC reader to attach ────────────
        //
        // The host's notification-only `PipePaneReader` extracts OSC 9;4 the
        // same way it extracts OSC 9 / OSC 777 notifications. `pane_pipe == 1`
        // means tmux has the pipe-pane attached and the reader is consuming.

        TestStep.waitForTmuxDisplayMessage(
            target: "e2e-progress:0.0",
            format: "#{pane_pipe}",
            contains: "1",
            timeout: 25
        )

        // ── Phase 5: Baseline — no progress bar yet ──────────────────────

        TestStep.log("Baseline: no progress emitted yet, the bar must NOT be present")
        TestStep.macScreenshot(label: "host-baseline-no-progress")
        TestStep.macScreenshot(label: "viewer-baseline-no-progress", instance: 1)
        TestStep.iosScreenshot(label: "ios-baseline-no-progress")

        // ── Phase 6: Determinate progress (state=1, 50%) ─────────────────
        //
        // Blue bar filled to 50% on all three platforms.

        TestStep.log("Phase 6: emitting OSC 9;4;1;50 — blue bar at 50%")
        Shortcut.tmuxRunCommand(
            target: "e2e-progress:0.0",
            command: "printf '\\e]9;4;1;50\\a'"
        )

        // Each wait pairs the constant accessibility label with a state-specific
        // value substring (`TerminalProgressBar.accessibilityValue`), so the
        // waiter actually proves the bar reached the expected state on that
        // platform — not just that *some* progress bar is rendering. Catches
        // wrong-state-propagated bugs before the screenshot stage.
        TestStep.macWaitForElementQuery(
            .allOf([.label("Terminal progress"), .valueContains("50%")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "host-progress-50")
        TestStep.macWaitForElementQuery(
            .allOf([.label("Terminal progress"), .valueContains("50%")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-progress-50", instance: 1)
        TestStep.iosWaitForElement(
            .allOf([.label("Terminal progress"), .valueContains("50%")]),
            timeout: 5
        )
        TestStep.iosScreenshot(label: "ios-progress-50")

        // ── Phase 7: Warning (state=4) ───────────────────────────────────
        //
        // Full yellow bar. Tests that a state transition without a progress
        // value still propagates correctly.

        TestStep.log("Phase 7: emitting OSC 9;4;4 — full yellow warning bar")
        Shortcut.tmuxRunCommand(
            target: "e2e-progress:0.0",
            command: "printf '\\e]9;4;4\\a'"
        )

        TestStep.macWaitForElementQuery(
            .allOf([.label("Terminal progress"), .valueContains("warning")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "host-progress-warning")
        TestStep.macWaitForElementQuery(
            .allOf([.label("Terminal progress"), .valueContains("warning")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-progress-warning", instance: 1)
        TestStep.iosWaitForElement(
            .allOf([.label("Terminal progress"), .valueContains("warning")]),
            timeout: 5
        )
        TestStep.iosScreenshot(label: "ios-progress-warning")

        // ── Phase 8: Error (state=2) ─────────────────────────────────────
        //
        // Full red bar.

        TestStep.log("Phase 8: emitting OSC 9;4;2 — full red error bar")
        Shortcut.tmuxRunCommand(
            target: "e2e-progress:0.0",
            command: "printf '\\e]9;4;2\\a'"
        )

        TestStep.macWaitForElementQuery(
            .allOf([.label("Terminal progress"), .valueContains("error")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "host-progress-error")
        TestStep.macWaitForElementQuery(
            .allOf([.label("Terminal progress"), .valueContains("error")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-progress-error", instance: 1)
        TestStep.iosWaitForElement(
            .allOf([.label("Terminal progress"), .valueContains("error")]),
            timeout: 5
        )
        TestStep.iosScreenshot(label: "ios-progress-error")

        // ── Phase 9: Cleared (state=0) ───────────────────────────────────
        //
        // Bar must disappear on every platform — `setPaneProgress` normalises
        // `.removed` to `nil`, and the parent views render nothing for `nil`.

        TestStep.log("Phase 9: emitting OSC 9;4;0 — bar cleared on all platforms")
        Shortcut.tmuxRunCommand(
            target: "e2e-progress:0.0",
            command: "printf '\\e]9;4;0\\a'"
        )
        TestStep.wait(seconds: 2)

        TestStep.macWaitForElementToDisappear(titled: "Terminal progress", timeout: 5)
        TestStep.macScreenshot(label: "host-progress-cleared")
        TestStep.macWaitForElementToDisappear(titled: "Terminal progress", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-progress-cleared", instance: 1)
        TestStep.iosWaitForElementToDisappear(.label("Terminal progress"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-progress-cleared")
    }
}
