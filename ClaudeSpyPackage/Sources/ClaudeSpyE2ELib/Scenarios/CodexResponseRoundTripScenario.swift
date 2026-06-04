import Foundation

/// E2E scenario: Codex response round-trip (reply-after-stop).
///
/// A Codex `Stop` opens a reply form on iOS; submitting a reply delivers
/// Codex-flavored keystrokes (the reply text + Enter) into the pane backing the
/// session. Exercises `CodexKeystrokes` delivery end-to-end — the Codex analogue
/// of the Claude AskUserQuestion keystroke proof.
public enum CodexResponseRoundTripScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Codex Response Round Trip",
        tags: ["hooks", "codex", "response"]
    ) {
        // 1. Pair + a tmux session for the Codex session.
        FreshPairingScenario.scenario
        TestStep.tmuxCreateSession(name: "codex-reply", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "codex-reply:0.0", storeAs: "codexReplyPane")
        TestStep.iosWaitForElement(.labelContains("codex-reply"), timeout: 15)

        // 2. Codex SessionStart so the session shows as a Codex session.
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-codex-reply-1",
                "cwd": "/Users/test/CodexReplyApp",
                "timestamp": "2026-05-31T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${codexReplyPane}"
        )
        TestStep.iosWaitForElement(.labelContains("CodexReplyApp"), timeout: 10)

        // 3. Codex Stop → the session is "Done" (doneWorking needs attention) and
        //    a reply form opens.
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "e2e-codex-reply-1",
                "cwd": "/Users/test/CodexReplyApp",
                "timestamp": "2026-05-31T10:01:00.000000Z",
                "last_assistant_message": "Codex finished the task."
            }
            """,
            tmuxPane: "${codexReplyPane}"
        )
        TestStep.iosWaitForElement(.labelContains("Done"), timeout: 10)

        // 4. Open the session → the agent-blind reply-after-stop form (its
        //    placeholder is "Reply to the agent…", not Codex-specific).
        TestStep.iosTap(.labelContains("CodexReplyApp"))
        TestStep.iosWaitForElement(.labelContains("Reply to the agent"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-codex-reply-form")

        // 5. Type a distinctive reply and send it. The reply text + Enter are
        //    delivered to the pane; capture the pane to prove the bytes landed.
        TestStep.iosTap(.labelContains("Reply to the agent"))
        TestStep.iosType(text: "codexreplymarker")
        TestStep.iosTap(.label("Send"))
        TestStep.wait(seconds: 6)
        TestStep.iosScreenshot(label: "ios-codex-reply-sent", compare: false)

        TestStep.tmuxCapturePaneContent(target: "codex-reply:0", storeAs: "codexReplyPaneContent")
        TestStep.assertStoredContains(key: "codexReplyPaneContent", substring: "codexreplymarker")
    }
}
