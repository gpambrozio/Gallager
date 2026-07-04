import Foundation

/// E2E scenario: a `Stop` hook without `last_assistant_message` is a subagent
/// stop and must not drive the main session's state.
///
/// Regression test for the mid-task "Done" flip. Subagents fire the plain
/// `Stop` hook too, not always with an `agent_id` for the pre-parse subagent
/// drop to see; only main-agent stops carry `last_assistant_message`. Before
/// the fix, a message-less Stop flipped a Working session to "Done" (and fired
/// a bogus "waiting for your input" notification) while the main agent was
/// still mid-task.
///
/// 1. A tmux pane is bound to a Claude session (`SessionStart`) and put to
///    work (`UserPromptSubmit` → "Working").
/// 2. A message-less `Stop` arrives — the session must STAY "Working".
///    Without the fix this phase shows "Done" and the Working wait fails.
/// 3. A real main-agent `Stop` (with `last_assistant_message`) arrives — the
///    session goes to "Done", proving main stops still land.
public enum SubagentStopIgnoredScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Subagent Stop Ignored",
        tags: ["hooks", "sessions", "macos-only"]
    ) {
        // 1. Launch the host and open the Panes window.
        Shortcut.macOnlySetup

        // 2. Create a pane and bind it to a Claude session.
        TestStep.tmuxCreateSession(name: "subagent-stop", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "subagent-stop:0.0", storeAs: "paneId")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-subagent-stop-session",
                "timestamp": "2026-02-14T10:00:00.000000Z",
                "source": "startup"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/SubagentProject"
        )
        TestStep.macWaitForElement(titled: "Idle", timeout: 10)

        // 3. Put the session to work.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-subagent-stop-session",
                "timestamp": "2026-02-14T10:00:05.000000Z",
                "prompt": "do something"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/SubagentProject"
        )
        TestStep.macWaitForElement(titled: "Working", timeout: 10)
        TestStep.macScreenshot(label: "mac-working")

        // 4. THE BUG — a subagent's Stop: same hook, no last_assistant_message.
        //    It must be dropped, leaving the session "Working".
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "e2e-subagent-stop-session",
                "timestamp": "2026-02-14T10:00:10.000000Z",
                "stop_hook_active": true
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/SubagentProject"
        )
        // Deliberate fixed wait: a *dropped* frame produces no observable
        // signal, so give the ingress pipeline time to have applied the state
        // flip if it were (wrongly) going to. Only then assert the row still
        // says "Working" — with one session, "Working" present ⇒ not "Done".
        TestStep.wait(seconds: 3)
        TestStep.macWaitForElement(titled: "Working", timeout: 5)
        TestStep.macScreenshot(label: "mac-still-working-after-subagent-stop")

        // 5. A real main-agent Stop (carries the message) still lands → "Done".
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "e2e-subagent-stop-session",
                "timestamp": "2026-02-14T10:00:15.000000Z",
                "stop_hook_active": true,
                "last_assistant_message": "Task complete"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/SubagentProject"
        )
        TestStep.macWaitForElement(titled: "Done", timeout: 10)
        TestStep.macScreenshot(label: "mac-done-after-main-stop")
    }
}
