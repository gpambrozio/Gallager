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

        // Each phase asserts the bar's actual state on every platform before
        // screenshotting, so a wrong-state-propagated bug fails at the wait
        // (with a named state in the failure message) instead of slipping
        // through to a screenshot diff. The bar's `.accessibilityLabel`
        // ("Terminal progress") is concatenated into the parent row's
        // combined AX label, and its `.accessibilityValue` ("50%", "warning",
        // "error", "in progress") is concatenated into the row's combined
        // AX value, so `labelContains` + `valueContains` matches both the
        // collapsed-Button row on macOS and the bar's own element on iOS.
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("Terminal progress"), .valueContains("50%")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "host-progress-50")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("Terminal progress"), .valueContains("50%")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-progress-50", instance: 1)
        TestStep.iosWaitForElement(
            .allOf([.labelContains("Terminal progress"), .valueContains("50%")]),
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
            .allOf([.labelContains("Terminal progress"), .valueContains("warning")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "host-progress-warning")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("Terminal progress"), .valueContains("warning")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-progress-warning", instance: 1)
        TestStep.iosWaitForElement(
            .allOf([.labelContains("Terminal progress"), .valueContains("warning")]),
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
            .allOf([.labelContains("Terminal progress"), .valueContains("error")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "host-progress-error")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("Terminal progress"), .valueContains("error")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-progress-error", instance: 1)
        TestStep.iosWaitForElement(
            .allOf([.labelContains("Terminal progress"), .valueContains("error")]),
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

        // The bar's mirrored label always starts with "Terminal progress",
        // so a substring check covers every state and disappears together
        // with the bar when the parent stops rendering it.
        TestStep.macWaitForElementToDisappear(titled: "Terminal progress", timeout: 5)
        TestStep.macScreenshot(label: "host-progress-cleared")
        TestStep.macWaitForElementToDisappear(
            titled: "Terminal progress",
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-progress-cleared", instance: 1)
        TestStep.iosWaitForElementToDisappear(.labelContains("Terminal progress"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-progress-cleared")

        // ── Phase 10: Mirror the pane, verify progress still flows ───────
        //
        // Regression guard: opening a pane in the host mirror tears down
        // its notification-only `PipePaneReader` and replaces it with a
        // `PaneStream`-owned reader that takes over the same pipe-pane
        // FIFO (`PaneStreamManager.subscribe` line ~229). If the
        // `PaneStream` doesn't wire `setProgressHandler` on its reader,
        // OSC 9;4 sequences are still parsed but the resulting
        // `TerminalProgressState` is dropped on the floor — the host
        // sidebar bar (and every relayed viewer) freezes on whatever
        // value arrived just before the mirror switch.
        //
        // Phase 9 left the bar cleared everywhere, so a fresh 75% value
        // here proves the mirrored-pane path forwards progress correctly.

        TestStep.log("Phase 10: select ProgressTest in host sidebar to start mirroring")
        TestStep.macCGClick(titled: "ProgressTest")

        // TerminalContainerView.onAppear → PaneStreamManager.subscribe()
        // awaits stopNotificationReader, then PaneStream.connect (pipe-pane
        // start + initial capture) — ~1s in practice; allow some headroom.
        TestStep.wait(seconds: 2)

        TestStep.log("Phase 10a: emitting OSC 9;4;1;75 while ProgressTest is mirrored")
        Shortcut.tmuxRunCommand(
            target: "e2e-progress:0.0",
            command: "printf '\\e]9;4;1;75\\a'"
        )

        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("Terminal progress"), .valueContains("75%")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "host-mirrored-progress-75")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("Terminal progress"), .valueContains("75%")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-mirrored-progress-75", instance: 1)
        TestStep.iosWaitForElement(
            .allOf([.labelContains("Terminal progress"), .valueContains("75%")]),
            timeout: 5
        )
        TestStep.iosScreenshot(label: "ios-mirrored-progress-75")

        TestStep.log("Phase 10b: clearing bar from mirrored pane")
        Shortcut.tmuxRunCommand(
            target: "e2e-progress:0.0",
            command: "printf '\\e]9;4;0\\a'"
        )

        TestStep.macWaitForElementToDisappear(titled: "Terminal progress", timeout: 5)
        TestStep.macScreenshot(label: "host-mirrored-progress-cleared")
        TestStep.macWaitForElementToDisappear(
            titled: "Terminal progress",
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-mirrored-progress-cleared", instance: 1)
        TestStep.iosWaitForElementToDisappear(.labelContains("Terminal progress"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-mirrored-progress-cleared")
    }
}
