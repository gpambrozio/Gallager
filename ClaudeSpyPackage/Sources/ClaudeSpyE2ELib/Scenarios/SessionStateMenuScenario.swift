import Foundation

/// E2E scenario: manually setting a session's state from the sidebar's
/// right-click "Set State" context menu (issue #695).
///
/// The gallager CLI's `session set-state` path is already covered by
/// `GallagerCLIScenario`; this scenario drives the *same* manual-override
/// mechanism through the new host **context menu** instead, and proves the
/// headline requirement: a manual choice is overridden the moment an agent
/// plugin reports a fresh state.
///
/// A single Claude session (`e2e-state`, project "StateProject") is created on
/// the host, so it starts idle. The scenario then, via right-click → "Set
/// State":
///   1. Sets Working, Waiting for input, and Idle in turn — each must flip the
///      sidebar status indicator (exposed as hidden status text on the row).
///   2. Re-sets Working, then picks "Automatic" to clear the override — the row
///      must revert to the agent's own state (Idle).
///   3. Re-sets Waiting for input, then delivers a `UserPromptSubmit` hook. The
///      plugin state (Working) must win, clearing the manual override — this is
///      the "an agent plugin overrides the user's choice" guarantee.
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

        // ── Phase 1: set each state via the "Set State" submenu ──────────

        TestStep.log("Host setting StateProject → Working via 'Set State' submenu")
        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Working"
        )
        TestStep.macWaitForElement(titled: "Working", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Idle", timeout: 15)
        TestStep.macScreenshot(label: "state-working")

        TestStep.log("Host setting StateProject → Waiting for input via 'Set State' submenu")
        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Waiting for input"
        )
        TestStep.macWaitForElement(titled: "Waiting for input", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Working", timeout: 15)
        TestStep.macScreenshot(label: "state-waiting")

        TestStep.log("Host setting StateProject → Idle via 'Set State' submenu")
        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Idle"
        )
        TestStep.macWaitForElement(titled: "Idle", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Waiting for input", timeout: 15)
        TestStep.macScreenshot(label: "state-idle-override")

        // ── Phase 2: "Automatic" clears the override ────────────────────
        //
        // Re-set Working so the override differs from the agent's idle state,
        // then clear it — the row must fall back to Idle.

        TestStep.log("Host re-setting StateProject → Working, then clearing via 'Automatic'")
        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Working"
        )
        TestStep.macWaitForElement(titled: "Working", timeout: 15)

        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Automatic"
        )
        TestStep.macWaitForElement(titled: "Idle", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Working", timeout: 15)
        TestStep.macScreenshot(label: "state-automatic-cleared")

        // ── Phase 3: a plugin state update overrides the manual choice ───
        //
        // Pin the session to "Waiting for input", then deliver a
        // UserPromptSubmit hook. The plugin flips the session to Working and
        // clears the manual override — the guarantee from issue #695.

        TestStep.log("Host setting StateProject → Waiting for input, then delivering a plugin hook")
        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Waiting for input"
        )
        TestStep.macWaitForElement(titled: "Waiting for input", timeout: 15)

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-state-session",
                "timestamp": "2026-07-30T10:05:00.000000Z",
                "prompt": "kick off a task"
            }
            """,
            tmuxPane: "${statePaneId}",
            projectPath: "/Users/test/StateProject"
        )
        TestStep.macWaitForElement(titled: "Working", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Waiting for input", timeout: 15)
        TestStep.macScreenshot(label: "state-plugin-overrides-manual")
    }
}
