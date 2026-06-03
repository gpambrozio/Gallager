import Foundation

/// E2E scenario: the ingress socket round-trip via the reference `EchoPluginCore`
/// (spec §17.3). Unlike the hook-driven scenarios (which route real Claude hook
/// JSON to `ClaudeCodePluginCore`), this drives the **deterministic** echo core:
/// the frame payload is an `EchoDirective` whose fields become — verbatim — the
/// `PluginEvent` the app dispatches. That lets the test pin exactly which status
/// bits and project name surface on iOS, independent of any real agent semantics.
///
/// Flow proven end-to-end:
///   DSL writes a length-prefixed frame (`plugin_id: "echo"`) to the per-scenario
///   ingress socket → `IngressSocketServer` routes it to `EchoPluginCore.handleIngress`
///   → the returned `PluginEvent` flows through the dispatcher → the Mac stamps the
///   session (project name from `projectPath`, attention bit) → it forwards
///   `agent_session_status` to the paired iOS viewer → iOS renders the session.
public enum EchoIngressRoundTripScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Echo Ingress Round Trip",
        tags: ["plugin", "ingress", "echo"]
    ) {
        // Fresh pairing + two tmux panes (stores ${pane1Id} / ${pane2Id}).
        ClaudeSessionsShowScenario.scenario

        // 1. Drive the echo core: bind pane 1 to an echo session that needs
        //    attention, with a project path the sidebar renders as "EchoLab". The
        //    `state` (a `doneWorking` AgentState here) maps straight onto the
        //    PluginEvent; `doneWorking` derives `needsAttention == true`.
        TestStep.macSendHookEvent(
            pluginID: "echo",
            json: """
            {
                "sessionID": "e2e-echo-session-1",
                "state": { "doneWorking": { "summary": null } },
                "projectPath": "/Users/test/EchoLab"
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 2. iOS shows pane 1 as an (echo) agent session named after the project
        //    directory — proving the frame round-tripped through the real socket
        //    transport, the echo core, the dispatcher, and the iOS forward path.
        TestStep.iosWaitForElement(.labelContains("EchoLab"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-echo-session-attention")

        // 3. A second directive flips the session to "working" (clears attention).
        //    `agent_session_status` updates the same session in place.
        TestStep.macSendHookEvent(
            pluginID: "echo",
            json: """
            {
                "sessionID": "e2e-echo-session-1",
                "state": { "working": {} },
                "projectPath": "/Users/test/EchoLab"
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 4. Still the same session (project name persists); pane 2 stays a plain
        //    terminal throughout.
        TestStep.iosWaitForElement(.labelContains("EchoLab"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("session-2"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-echo-session-working")
    }
}
