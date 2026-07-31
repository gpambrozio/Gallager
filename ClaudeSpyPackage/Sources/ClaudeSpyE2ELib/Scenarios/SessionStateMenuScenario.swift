import Foundation

/// E2E scenario: manually setting a session's state from the sidebar's
/// right-click "Set State" context menu (issue #695).
///
/// A single Claude session (`e2e-state`, project "StateProject") is created on
/// the host, so it starts idle. Via right-click → "Set State" the scenario
/// pins Waiting for input, then Idle, then re-pins Waiting for input and clears
/// it with "Automatic" — verifying the sidebar indicator follows the manual
/// choice each time and reverts to the agent's own state when cleared.
///
/// Every right-click targets a row showing the idle moon or the attention bell
/// (static glyphs). We deliberately never right-click a row in the *Working*
/// state: that row renders a `ProgressView`, which SwiftUI merges into an
/// `AXBusyIndicator` that swallows the row's accessibility children, so a
/// context menu can't be opened on it (the same merge the sidebar works around
/// elsewhere with `SessionProgressAccessibilityProxy`).
///
/// The complementary guarantee — that a later plugin state update *clears* the
/// override so a live agent always wins — is the existing `applyState` behavior
/// already e2e-proven by `GallagerCLIScenario` ("hook events override CLI
/// state"): the menu writes the very same `cliSessionState` field the CLI does,
/// so both are cleared by the same code. It isn't re-driven here because
/// reliably re-triggering a *definite* plugin state onto an already-running
/// agent session mid-scenario is flaky in the harness.
///
/// Host-only (`macos-only`): the viewer-to-host `SetSessionState` command path
/// rides the same relay plumbing as `SetSessionColor`, which
/// `SessionColorSyncScenario` already exercises end-to-end.
public enum SessionStateMenuScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Session State Menu",
        tags: ["macos-only", "state"]
    ) {
        // ── Setup: one Claude session on the host ───────────────────────

        TestStep.tmuxCreateSession(name: "e2e-state", width: 100, height: 30)

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        TestStep.tmuxStorePaneId(target: "e2e-state:0.0", storeAs: "statePaneId")

        // SessionStart makes the row a Claude session sitting idle, so each
        // override below is a visible change from the agent's own state.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-state-session",
                "timestamp": "2026-07-30T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${statePaneId}",
            projectPath: "/Users/test/StateProject"
        )

        TestStep.macWaitForElement(titled: "StateProject", timeout: 30)
        TestStep.macWaitForElement(titled: "Idle", timeout: 15)
        TestStep.macScreenshot(label: "state-idle-baseline")

        // ── Phase 1: pin "Waiting for input" via the "Set State" submenu ─
        //
        // Right-clicks the idle row (a static moon glyph). The row flips to the
        // attention bell — also a static glyph, so it stays right-clickable.

        TestStep.log("Host setting StateProject → Waiting for input via 'Set State' submenu")
        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Waiting for input"
        )
        TestStep.macWaitForElement(titled: "Waiting for input", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Idle", timeout: 15)
        TestStep.macScreenshot(label: "state-waiting")

        // ── Phase 2: pin "Idle" (right-clicking the bell row) ───────────

        TestStep.log("Host setting StateProject → Idle via 'Set State' submenu")
        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Idle"
        )
        TestStep.macWaitForElement(titled: "Idle", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Waiting for input", timeout: 15)
        TestStep.macScreenshot(label: "state-idle-override")

        // ── Phase 3: "Automatic" clears the override ────────────────────
        //
        // Re-pin Waiting for input so the override differs from the agent's idle
        // state, then clear it — the row must fall back to the agent's Idle.

        TestStep.log("Host re-setting StateProject → Waiting for input, then clearing via 'Automatic'")
        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Waiting for input"
        )
        TestStep.macWaitForElement(titled: "Waiting for input", timeout: 15)

        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Automatic"
        )
        TestStep.macWaitForElement(titled: "Idle", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Waiting for input", timeout: 15)
        TestStep.macScreenshot(label: "state-automatic-cleared")
    }
}
