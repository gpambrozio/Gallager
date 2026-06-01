import Foundation

/// E2E scenario: "Close pane when Claude exits" preference + SessionEnd gating.
///
/// Guards the close-pane-on-session-end feature and its eligibility gating:
/// with the preference ON, a clean prompt-input exit (SessionEnd reason
/// `prompt_input_exit`) closes the pane, while a non-eligible reason
/// (`user_quit`) leaves it open. (The poll-until-agent-exits wait collapses to
/// a fast close here because the synthetic e2e pane runs a plain shell, not a
/// real agent process — the gating is what's verified.)
public enum ClosePaneOnSessionEndScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Close Pane On Session End",
        tags: ["hooks", "sessions", "macos-only"]
    ) {
        // 1. Two sessions: one we keep, one we expect to be closed.
        TestStep.tmuxCreateSession(name: "closepane-keep", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "closepane-exit", width: 80, height: 24)
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        // 2. Enable the "close pane when Claude exits" preference (General tab,
        //    "Claude Code" section — far down the form, so focus it to scroll it
        //    into view, then toggle with Space). Verify it actually flipped on.
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        // The "Claude Code" section is below the fold; scroll the settings form
        // to the bottom, then back up a little so the "Close pane when Claude
        // exits" toggle lands fully in view (not clipped at the top edge).
        TestStep.macScrollWheel(deltaY: -5, count: 20)
        TestStep.wait(seconds: 1)
        TestStep.macScrollWheel(deltaY: 5, count: 4)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-settings-scrolled", compare: false)
        // AXPress is a no-op on a SwiftUI Toggle, so use a real click on the
        // switch (far-right of the row) matched by the toggle's help text.
        TestStep.macCGClickElement(
            query: .help("Automatically close the tmux pane after Claude Code exits normally"),
            pointInRect: { CGPoint(x: $0.maxX - 20, y: $0.midY) }
        )
        TestStep.macWaitForElementQuery(
            .allOf([
                .help("Automatically close the tmux pane after Claude Code exits normally"),
                .valueContains("1"),
            ]),
            timeout: 5
        )
        TestStep.macCloseWindow(titled: "General")
        TestStep.wait(seconds: 1)

        // 3. Store pane ids for the hook events; confirm both sessions present.
        TestStep.tmuxStorePaneId(target: "closepane-keep:0.0", storeAs: "keepPane")
        TestStep.tmuxStorePaneId(target: "closepane-exit:0.0", storeAs: "exitPane")
        TestStep.macWaitForElement(titled: "closepane-keep", timeout: 5)
        TestStep.macWaitForElement(titled: "closepane-exit", timeout: 5)

        // 4. Negative: SessionEnd with a non-eligible reason → pane stays open.
        //    (No projectPath, so the sidebar keeps the tmux session name.)
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionEnd",
                "session_id": "closepane-keep-session",
                "timestamp": "2026-05-31T10:00:00.000000Z",
                "reason": "user_quit"
            }
            """,
            tmuxPane: "${keepPane}"
        )
        TestStep.wait(seconds: 5)
        TestStep.macWaitForElement(titled: "closepane-keep", timeout: 5)

        // 5. Eligible: SessionEnd with prompt_input_exit → pane closes.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionEnd",
                "session_id": "closepane-exit-session",
                "timestamp": "2026-05-31T10:01:00.000000Z",
                "reason": "prompt_input_exit"
            }
            """,
            tmuxPane: "${exitPane}"
        )
        TestStep.macWaitForElementToDisappear(titled: "closepane-exit", timeout: 20)
        TestStep.macScreenshot(label: "mac-pane-closed-on-session-end", compare: false)

        // 6. The non-eligible session is still present.
        TestStep.macWaitForElement(titled: "closepane-keep", timeout: 5)
    }
}
