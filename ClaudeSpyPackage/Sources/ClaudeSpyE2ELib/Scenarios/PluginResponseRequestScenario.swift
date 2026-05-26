import ClaudeSpyNetworking
import Foundation

/// E2E scenario: Plugin permission response round-trip (Spec §15.3 #4).
///
/// Verifies the `AgentResponseRequest.permission` round-trip on the new
/// plugin runtime:
/// 1. EchoPlugin emits a `permission` response request.
/// 2. iOS renders `PermissionRequestResponseView` with the description.
/// 3. The user taps "Allow", which submits an `AgentResponse.permission`
///    with `.allow` and `appliedSuggestionId: nil`.
/// 4. The Mac's `PluginManager.deliverResponse` forwards the response back
///    to EchoSidecar's `handleDeliverResponse`, which writes the JSON
///    payload to `${state_dir}/responses/<request_id>.json`.
/// 5. The scenario reads the response file and asserts on the `decision`
///    field — the structured contract round-tripped intact.
public enum PluginResponseRequestScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Response Request",
        tags: ["plugins", "echo", "permission"]
    ) {
        FreshPairingScenario.scenario

        TestStep.macSpawnSidecar(
            pluginID: "echo",
            fixtureSourcePath: URL(fileURLWithPath: "Fixtures/EchoPlugin"),
            instance: 0
        )

        TestStep.tmuxCreateSession(name: "echo-perm", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "echo-perm:0.0", storeAs: "paneId")

        // 1. Send a `_test: "request_permission"` payload. Echo mints
        //    `echo-req-1` as the request id (sequence resets per process).
        TestStep.macSendRawHookPayload(
            pluginID: "echo",
            json: .object([
                "_test": .string("request_permission"),
                "tool_name": .string("Bash"),
                "description": .string("Run a test command"),
                "session_id": .string("echo-perm-session"),
                "is_auto_approvable": .bool(false),
            ]),
            env: ["TMUX_PANE": "${paneId}"]
        )

        // 2. iOS displays the permission form. Tap into the session row,
        //    then assert on the descriptive text + the Allow/Deny pair.
        TestStep.iosWaitForElement(.valueContains("Attention"), timeout: 15)
        TestStep.iosTap(.valueContains("Attention"))
        TestStep.iosWaitForElement(.labelContains("Run a test command"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("Allow"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Deny"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-permission-prompt")

        // 3. Tap Allow. The submit path posts `agent_response_submission`
        //    over the viewer WebSocket; the Mac's connectedViewerManager
        //    routes it into `PluginManager.deliverResponse(...)`, which
        //    sends `deliver_response` JSON-RPC into the sidecar's stdin.
        TestStep.iosTap(.labelContains("Allow"))
        // The form dismisses on submit; the response-file check below
        // proves the round-trip worked. No "Allowed" feedback element
        // exists in the current UI flow.
        TestStep.wait(seconds: 1.5)
        TestStep.iosScreenshot(label: "ios-permission-allowed")

        // 4. EchoSidecar persists the response to
        //    `${state_dir}/responses/echo-req-1.json`. Poll for the file
        //    so the assertion below doesn't race the disk write.
        TestStep.waitForFileContains(
            path: "${echoResponsesDir}/echo-req-1.json",
            substring: "allow",
            storeAs: "permResponseJSON",
            timeout: 10
        )

        // 5. The payload should encode an `AgentResponse.permission` with
        //    `decision: "allow"`. The Echo encoder uses snake_case so the
        //    `appliedSuggestionId` field appears as `applied_suggestion_id`.
        TestStep.assertStoredContains(
            key: "permResponseJSON",
            substring: "\"decision\":\"allow\""
        )
        TestStep.assertStoredContains(
            key: "permResponseJSON",
            substring: "\"type\":\"permission\""
        )
    }
}
