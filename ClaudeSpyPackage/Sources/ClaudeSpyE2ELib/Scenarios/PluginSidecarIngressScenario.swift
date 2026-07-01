import Foundation

/// E2E scenario: ingress socket round-trip via the out-of-process
/// `EchoPluginSidecar` (spec §17.3 — sidecar channel).
///
/// The orchestrator stages a folder-dropped `echo-sidecar` plugin in the E2E
/// sandbox before the app launches. On startup, `AppCoordinator` discovers the
/// plugin under `<gallagerRoot>/plugins/echo-sidecar/`, spawns the
/// `EchoPluginSidecar` binary, and registers it with the plugin runtime.
///
/// Flow proven end-to-end:
///   DSL writes a length-prefixed frame (`plugin_id: "echo-sidecar"`) to the
///   per-scenario ingress socket → `IngressSocketServer` routes it to
///   `SidecarPluginCore.handleIngress` → the host sends it to the running
///   `EchoPluginSidecar` process via the sidecar RPC `translate_event` call →
///   the sidecar returns a `PluginEvent` → the Mac stamps the session (project
///   name from `projectPath`, attention bit) → it forwards
///   `agent_session_status` to the paired iOS viewer → iOS renders the session.
public enum PluginSidecarIngressScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Sidecar Ingress Round Trip",
        tags: ["plugin", "sidecar", "ingress"]
    ) {
        // 1. Stage the echo-sidecar fixture before the app launches so it is
        //    present in the folder-drop directory on startup.
        TestStep.macStageSidecarFixture(id: "echo-sidecar")

        // 2. Fresh pairing + two tmux panes (stores ${pane1Id} / ${pane2Id}).
        ClaudeSessionsShowScenario.scenario

        // 3. Drive the sidecar core: bind pane 1 to a sidecar echo session
        //    that needs attention, with a project path the sidebar renders as
        //    "SidecarLab". The `state` maps straight onto the PluginEvent;
        //    `doneWorking` derives `needsAttention == true`.
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            {
                "sessionID": "e2e-sidecar-session-1",
                "state": { "doneWorking": { "summary": null } },
                "projectPath": "/Users/test/SidecarLab"
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 4. iOS shows pane 1 as a sidecar agent session named after the project
        //    directory — proving the frame round-tripped through the real ingress
        //    socket, the sidecar process, the dispatcher, and the iOS forward path.
        TestStep.iosWaitForElement(.labelContains("SidecarLab"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-sidecar-session-attention")
    }
}
