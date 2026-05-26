import ClaudeSpyNetworking
import Foundation

/// E2E scenario: Plugin crash + supervisor restart (Spec §15.3 #2).
///
/// Verifies the `SidecarSupervisor`'s restart loop end-to-end:
/// 1. Spawn EchoPlugin via `--gallager-state-root`.
/// 2. Send `_test: "set_status"` and confirm iOS picks it up (sidecar
///    healthy, ingress socket bound, JSON-RPC flowing).
/// 3. Send `_test: "crash"` — the EchoSidecar calls `abort()`.
/// 4. Wait through the supervisor's first-crash 1 s backoff plus margin so
///    `restartAfterBackoff` re-spawns the process and `initialize` lands.
/// 5. Send another `_test: "set_status"` and confirm iOS reflects the new
///    state — the sidecar recovered without manual intervention.
public enum PluginCrashRestartScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Crash Restart",
        tags: ["plugins", "echo", "supervisor"]
    ) {
        FreshPairingScenario.scenario

        TestStep.macSpawnSidecar(
            pluginID: "echo",
            fixtureSourcePath: URL(fileURLWithPath: "Fixtures/EchoPlugin"),
            instance: 0
        )

        TestStep.tmuxCreateSession(name: "echo-crash", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "echo-crash:0.0", storeAs: "paneId")

        // Pre-crash: prove the sidecar is responsive end-to-end.
        TestStep.macSendRawHookPayload(
            pluginID: "echo",
            json: .object([
                "_test": .string("set_status"),
                "working": .bool(true),
                "attention": .bool(false),
                "session_id": .string("echo-crash-session"),
            ]),
            env: ["TMUX_PANE": "${paneId}"]
        )
        TestStep.iosWaitForElement(.valueContains("Working"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-pre-crash")

        // Force the sidecar to call abort(). `processControlPayload`
        // returns no PluginEvent on the crash path, so the `_test`
        // dispatch path terminates the process before the orchestrator
        // gets a translate_event response. The ingress write itself
        // succeeds (the socket buffered the frame before abort fired).
        TestStep.macSendRawHookPayload(
            pluginID: "echo",
            json: .object([
                "_test": .string("crash"),
            ]),
            env: ["TMUX_PANE": "${paneId}"]
        )

        // Supervisor backoff for crash #1 is 1 second (Spec §12). Sleep
        // through it plus margin so the supervisor finishes
        // `spawnAndInitialize` before we send the next payload — the
        // ingress write below blocks for up to 5 s waiting for the
        // socket file to re-appear, but we want the test to read the
        // recovery quickly even on a slow CI machine.
        TestStep.wait(seconds: 4)

        // Post-restart: prove the sidecar accepts new payloads. The
        // status should flip from `Working` to `Attention` if the ingress
        // socket rebinds and the JSON-RPC channel is back up.
        TestStep.macSendRawHookPayload(
            pluginID: "echo",
            json: .object([
                "_test": .string("set_status"),
                "working": .bool(false),
                "attention": .bool(true),
                "session_id": .string("echo-crash-session"),
            ]),
            env: ["TMUX_PANE": "${paneId}"]
        )
        TestStep.iosWaitForElement(.valueContains("Attention"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-post-restart")
    }
}
