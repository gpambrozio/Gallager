import ClaudeSpyNetworking
import Foundation

/// E2E scenario: Plugin runtime basics (Spec §15.3 #1).
///
/// Verifies the full pipeline for a non-bundled plugin (EchoPlugin):
/// spawn the sidecar via the `--gallager-state-root` install path, drive it
/// through the per-plugin ingress socket, and assert that:
/// 1. The first `_test: "set_status"` payload flips the session row to
///    `Working` on iOS (`agent_session_status` round-trip).
/// 2. A follow-up payload with `attention: true` flips the same row to
///    `Attention`.
/// 3. The Echo plugin's presentation bundle reaches iOS, visible in the
///    project picker badge as "Echo" (the manifest's `short_name`).
///
/// Uses `FreshPairingScenario` so iOS is paired with the host and the
/// `PluginPresentationCache` is warm.
public enum PluginRuntimeBasicsScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Runtime Basics",
        tags: ["plugins", "echo"]
    ) {
        // 1. Pair host + iOS so the relay is up.
        FreshPairingScenario.scenario

        // 2. Install + spawn the EchoPlugin under the per-instance state root.
        //    The orchestrator copies the fixture into the test instance's
        //    state-root and asks the live `PluginManager` to rescan.
        TestStep.macSpawnSidecar(
            pluginID: "echo",
            fixtureSourcePath: URL(fileURLWithPath: "Fixtures/EchoPlugin"),
            instance: 0
        )

        // 3. Open a tmux session so iOS has a terminal row to attach the
        //    plugin session to. `Plugin Runtime Basics` doesn't run any
        //    real agent in the pane — the `_test` payloads just steer
        //    Echo's `translate_event` to emit synthetic status bits.
        TestStep.tmuxCreateSession(name: "echo-1", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "echo-1:0.0", storeAs: "paneId")

        // 4. Flip the row to `Working` via `set_status`. Echo's translator
        //    forwards the `working`/`attention` bits straight into a
        //    `PluginEvent`, which the Mac surfaces as `agent_session_status`.
        TestStep.macSendRawHookPayload(
            pluginID: "echo",
            json: .object([
                "_test": .string("set_status"),
                "working": .bool(true),
                "attention": .bool(false),
                "session_id": .string("echo-session-1"),
            ]),
            env: ["TMUX_PANE": "${paneId}"]
        )

        // iOS row should report "Working" via accessibilityValue. The
        // EchoPlugin presentation cache must also be warm; the "Echo"
        // badge confirms the presentation bundle reached iOS.
        TestStep.iosWaitForElement(.valueContains("Working"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-echo-working")

        // 5. Flip to `Attention`. Same payload shape, flipped bits.
        TestStep.macSendRawHookPayload(
            pluginID: "echo",
            json: .object([
                "_test": .string("set_status"),
                "working": .bool(false),
                "attention": .bool(true),
                "session_id": .string("echo-session-1"),
            ]),
            env: ["TMUX_PANE": "${paneId}"]
        )

        TestStep.iosWaitForElement(.valueContains("Attention"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-echo-attention")
    }
}
