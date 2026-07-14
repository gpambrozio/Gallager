import Foundation

/// E2E scenario: Fresh-launch auto-select lands on the tmux-active window (issue #653)
///
/// Reproduces the bug where opening the Mac app with an existing multi-window
/// session auto-selected the wrong window. Setup:
/// - A session with two windows where **window 1** is the tmux-active window.
/// - A Claude session starts in **window 0** (the *non-active* window), which is
///   the first agent session to appear and triggers the app's auto-select.
///
/// Before the fix, the auto-select picked the window that merely *contained* the
/// agent pane (window 0), so the app opened on window 0 even though tmux's active
/// window was window 1. After the fix it lands on window 1 — matching what a
/// sidebar click already did. The final assertion (window 1 selected) times out
/// against the buggy build and passes against the fixed one.
public enum AutoSelectActiveWindowScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Auto Select Active Window",
        tags: ["sidebar", "tabs", "sessions", "hooks", "macos-only"]
    ) {
        // 1. Create a session whose second window is the tmux-active one.
        TestStep.log("Stage 1: Create a session with two windows, window 1 active in tmux")
        TestStep.tmuxCreateSession(name: "autosel", width: 160, height: 50)
        Shortcut.tmuxRunCommand(target: "autosel:0.0", command: "echo '=== WINDOW 0 (agent) ==='")
        Shortcut.tmuxRunCommand(target: "autosel:0.0", command: "tmux new-window -t autosel")

        // `new-window` creates window 1 and makes it the tmux-active window. Wait
        // until tmux confirms window 1 is active before addressing it — this also
        // confirms the window exists (addressing it too early fails with
        // "can't find window: 1"), and a fixed sleep would be racy on CI.
        TestStep.waitForTmuxDisplayMessage(
            target: "autosel:1.0",
            format: "#{window_active}",
            contains: "1",
            timeout: 10
        )

        // The agent will run in window 0 — the NON-active window.
        TestStep.tmuxStorePaneId(target: "autosel:0.0", storeAs: "agentPaneId")

        // 2. Launch the app fresh and open the Panes window. Nothing is selected
        //    yet (no agent session has appeared), so the auto-select baseline is
        //    captured empty and the next agent session will drive the selection.
        TestStep.log("Stage 2: Launch app — session visible, nothing selected")
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macWaitForElement(titled: "autosel", timeout: 15)
        TestStep.macScreenshot(label: "mac-launched-nothing-selected")

        // 3. A Claude session starts in window 0 (the non-active window). This is
        //    the first agent session to appear, so the app auto-selects it.
        TestStep.log("Stage 3: Claude session starts in window 0 — triggers auto-select")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "autosel-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${agentPaneId}",
            projectPath: "/Users/test/AutoSelProject"
        )

        // 4. The auto-selected window must be the tmux-ACTIVE window (window 1),
        //    not the window that contains the agent pane (window 0). Against the
        //    unfixed build this waits on a selection that never arrives and fails.
        TestStep.log("Stage 4: Verify window 1 (tmux-active) was auto-selected, not window 0")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("autosel:1"), .valueContains("selected")]),
            timeout: 15
        )
        TestStep.macScreenshot(label: "mac-auto-selected-active-window")
    }
}
