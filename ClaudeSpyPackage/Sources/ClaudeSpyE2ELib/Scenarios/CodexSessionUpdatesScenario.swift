import Foundation

/// E2E scenario: Codex session lifecycle (the Codex analogue of the Claude
/// session-updates flow).
///
/// Drives the Codex plugin core via codex-tagged ingress frames: SessionStart
/// shows the session (named from the payload `cwd`, since Codex has no
/// project-dir env var), UserPromptSubmit flips it to Working, and SessionEnd
/// removes the session so the pane reverts to a plain terminal. Exercises
/// `CodexTranslator` + the pane↔session pipeline that the Claude-only session
/// scenarios don't cover.
public enum CodexSessionUpdatesScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Codex Session Updates",
        tags: ["hooks", "sessions", "codex"]
    ) {
        // 1. Pair + a tmux session to host the Codex session.
        FreshPairingScenario.scenario
        TestStep.tmuxCreateSession(name: "codex-session", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "codex-session:0.0", storeAs: "codexPane")
        TestStep.iosWaitForElement(.labelContains("codex-session"), timeout: 15)

        // 2. Codex SessionStart — project name comes from the payload `cwd`.
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-codex-session-1",
                "cwd": "/Users/test/MyCodexApp",
                "timestamp": "2026-05-31T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${codexPane}"
        )
        TestStep.iosWaitForElement(.labelContains("MyCodexApp"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-codex-session")

        // 3. UserPromptSubmit → the agent is in its loop → Working.
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-codex-session-1",
                "cwd": "/Users/test/MyCodexApp",
                "timestamp": "2026-05-31T10:01:00.000000Z",
                "prompt": "Hello from Codex e2e"
            }
            """,
            tmuxPane: "${codexPane}"
        )
        TestStep.iosWaitForElement(.labelContains("Working"), timeout: 10)

        // 4. SessionEnd → the agent session is removed and the pane reverts to a
        //    plain terminal (commit 9a8c2683; Codex emits the same `.sessionEnded`
        //    app action). The "MyCodexApp" badge disappears and the pane shows as
        //    the plain "codex-session" terminal again.
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "SessionEnd",
                "session_id": "e2e-codex-session-1",
                "cwd": "/Users/test/MyCodexApp",
                "timestamp": "2026-05-31T10:02:00.000000Z",
                "reason": "user_quit"
            }
            """,
            tmuxPane: "${codexPane}"
        )
        TestStep.iosWaitForElementToDisappear(.labelContains("MyCodexApp"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("codex-session"), timeout: 5)
    }
}
