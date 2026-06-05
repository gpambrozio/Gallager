import Foundation

/// E2E scenario: a Claude session and a Codex session run **at the same time** in
/// two different panes, and each plugin's response form routes back to its own
/// pane/core.
///
/// Every other session scenario drives a single plugin in isolation; nothing
/// exercises the registry's multi-core routing with both cores live. This one
/// does: two `PluginCore`s are active, the iOS sidebar shows both sessions by
/// their (differently-derived) project names, and submitting a prompt from the
/// Claude session lands its keystrokes in the Claude pane while the Codex session's
/// reply lands in the Codex pane — never crossed.
public enum MultiPluginCoexistenceScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Multi Plugin Coexistence",
        tags: ["plugin", "codex", "sessions", "ios"]
    ) {
        // 1. Pair, then create one pane per agent.
        FreshPairingScenario.scenario
        TestStep.tmuxCreateSession(name: "coexist-cc", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "coexist-cx", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "coexist-cc:0.0", storeAs: "claudePane")
        TestStep.tmuxStorePaneId(target: "coexist-cx:0.0", storeAs: "codexPane")
        TestStep.iosWaitForElement(.labelContains("coexist-cc"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("coexist-cx"), timeout: 10)

        // 2. Start a Claude session on pane A (project name from projectPath).
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-coexist-claude",
                "timestamp": "2026-05-31T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${claudePane}",
            projectPath: "/Users/test/CoexistClaude"
        )

        // 3. Start a Codex session on pane B (project name from the payload `cwd`).
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-coexist-codex",
                "cwd": "/Users/test/CoexistCodex",
                "timestamp": "2026-05-31T10:00:01.000000Z"
            }
            """,
            tmuxPane: "${codexPane}"
        )

        // 4. Both plugins' sessions coexist in the iOS list, each named by its own
        //    core's project-resolution path.
        TestStep.iosWaitForElement(.labelContains("CoexistClaude"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("CoexistCodex"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-both-sessions")

        // 5. Open the Claude session → its agent-blind reply form. Submit a
        //    Claude-only marker; it must land in the Claude pane.
        TestStep.iosTap(.labelContains("CoexistClaude"))
        TestStep.iosWaitForElement(.labelContains("Reply to the agent"), timeout: 10)
        TestStep.iosTap(.labelContains("Reply to the agent"))
        TestStep.iosType(text: "alphaclaudekey")
        TestStep.iosTap(.label("Send"))
        TestStep.iosWaitForElement(.labelContains("Prompt submitted"), timeout: 10)

        // 6. Back to the list, open the Codex session → the same agent-blind reply
        //    form. Submit a Codex-only marker; it must land in the Codex pane.
        TestStep.iosTap(.label("Sessions"))
        TestStep.iosWaitForElement(.labelContains("CoexistCodex"), timeout: 10)
        TestStep.iosTap(.labelContains("CoexistCodex"))
        TestStep.iosWaitForElement(.labelContains("Reply to the agent"), timeout: 10)
        TestStep.iosTap(.labelContains("Reply to the agent"))
        TestStep.iosType(text: "betacodexkey")
        TestStep.iosTap(.label("Send"))
        TestStep.iosWaitForElement(.labelContains("Prompt submitted"), timeout: 10)
        TestStep.wait(seconds: 5)

        // 7. Routing proof: each marker landed in its own pane and nowhere else.
        TestStep.tmuxCapturePaneContent(target: "coexist-cc:0", storeAs: "claudePaneOut")
        TestStep.tmuxCapturePaneContent(target: "coexist-cx:0", storeAs: "codexPaneOut")
        TestStep.assertStoredContains(key: "claudePaneOut", substring: "alphaclaudekey")
        TestStep.assertStoredNotContains(key: "claudePaneOut", substring: "betacodexkey")
        TestStep.assertStoredContains(key: "codexPaneOut", substring: "betacodexkey")
        TestStep.assertStoredNotContains(key: "codexPaneOut", substring: "alphaclaudekey")
    }
}
