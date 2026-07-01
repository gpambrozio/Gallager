import Foundation

/// E2E scenario: sidecar crash + supervisor auto-restart (spec §12).
///
/// Drives the `EchoPluginSidecar`'s built-in abort hook: an `EchoDirective`
/// with `abort: true` causes the sidecar process to call `Foundation.abort()`.
/// The `SidecarSupervisor` detects the process exit, waits its backoff (1 s),
/// restarts the sidecar, and re-initializes it. A subsequent normal frame
/// then flows through the restarted process and surfaces on iOS — proving the
/// supervisor restart path is functional.
///
/// NOTE: A deliberate 4-second pause follows the abort directive so the
/// supervisor has time to detect the exit and complete the 1 s backoff restart
/// before we send the next frame. Using a fixed wait here rather than a
/// state-driven wait because the supervisor restart doesn't emit an observable
/// accessibility signal we can poll against.
public enum PluginCrashRestartScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Sidecar Crash Restart",
        tags: ["plugin", "sidecar", "crash"]
    ) {
        // 1. Stage the echo-sidecar fixture before the app launches.
        TestStep.macStageSidecarFixture(id: "echo-sidecar")

        // 2. Fresh pairing + two tmux panes (stores ${pane1Id} / ${pane2Id}).
        ClaudeSessionsShowScenario.scenario

        // 3. Send a working frame to confirm the sidecar is alive and surfaces
        //    a session on iOS (baseline before the crash).
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            {
                "sessionID": "e2e-crash-session-1",
                "state": { "working": {} },
                "projectPath": "/Users/test/SidecarCrash"
            }
            """,
            tmuxPane: "${pane1Id}"
        )
        TestStep.iosWaitForElement(.labelContains("SidecarCrash"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-sidecar-before-crash")

        // 4. Crash the sidecar: the `abort` field causes `Foundation.abort()`.
        //    The supervisor detects the exit and schedules a 1 s backoff restart.
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            {
                "sessionID": "e2e-crash-session-1",
                "state": { "working": {} },
                "projectPath": "/Users/test/SidecarCrash",
                "abort": true
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 5. Wait for supervisor to detect exit + complete the backoff restart (1 s
        //    backoff + process spawn + initialize round-trip ≈ 3–4 s total).
        TestStep.wait(seconds: 4)

        // 6. Send a normal frame to the restarted sidecar. If the supervisor
        //    restarted correctly, the sidecar is running again and the frame flows
        //    through to iOS.
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            {
                "sessionID": "e2e-crash-session-2",
                "state": { "doneWorking": { "summary": null } },
                "projectPath": "/Users/test/SidecarRestart"
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 7. iOS shows the post-restart session — proving the supervisor restarted
        //    the sidecar and the frame round-tripped successfully.
        TestStep.iosWaitForElement(.labelContains("SidecarRestart"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-sidecar-after-restart")
    }
}
