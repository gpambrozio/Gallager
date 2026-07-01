import Foundation

/// E2E scenario: response-form round-trip via the out-of-process
/// `EchoPluginSidecar` (spec §17.3 — sidecar channel).
///
/// Mirrors `EchoResponseRoundTripScenario` but routes through the real
/// `SidecarPluginCore` / sidecar-process boundary:
///
///   echo-sidecar `awaitingPermission` state → app forwards the open form to
///   iOS → iOS renders `PermissionRequestResponseView` → user types
///   deny-with-feedback + Send → iOS submits a structured
///   `AgentResponse.permission(.denyWithFeedback)` keyed by `requestID` → Mac
///   routes it to `SidecarPluginCore.deliverResponse` → sidecar RPC
///   `deliver_response` call → sidecar's `.denyWithFeedback` branch fires
///   `send_text` notification → host calls `sendText` on the session → the
///   text lands in the bound tmux pane.
public enum PluginSidecarResponseRoundTripScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Sidecar Response Round Trip",
        tags: ["plugin", "sidecar", "response"]
    ) {
        // 1. Stage the echo-sidecar fixture before the app launches.
        TestStep.macStageSidecarFixture(id: "echo-sidecar")

        // 2. Fresh pairing + two tmux panes (stores ${pane1Id} / ${pane2Id}).
        ClaudeSessionsShowScenario.scenario

        // 3. Bind pane 1 to a working sidecar echo session. Use the pane id AS
        //    the session id so the sidecar's later sendText resolves the session
        //    back to this pane.
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            {
                "sessionID": "${pane1Id}",
                "state": { "working": {} },
                "projectPath": "/Users/test/SidecarLab"
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 4. Open the sidecar session on iOS so the response form can render.
        TestStep.iosWaitForElement(.labelContains("SidecarLab"), timeout: 15)
        TestStep.iosTap(.labelContains("SidecarLab"))
        TestStep.iosWaitForElement(.labelContains("Commands"), timeout: 15)

        // 5. Drive a blocking permission form through the sidecar core.
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            {
                "sessionID": "${pane1Id}",
                "state": {
                    "awaitingPermission": {
                        "_0": {
                            "title": "Sidecar wants to run a command",
                            "description": "sidecar response round-trip",
                            "isAutoApprovable": false,
                            "suggestions": [],
                            "allowsCustomInstructions": true
                        },
                        "requestID": "sidecar-perm-req-1"
                    }
                },
                "projectPath": "/Users/test/SidecarLab"
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 6. iOS renders the permission form.
        TestStep.iosWaitForElement(.labelContains("Accept"), timeout: 10)
        TestStep.iosWaitForElement(.identifier("permission-custom-instructions"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-sidecar-permission-form")

        // 7. Type the marker into the deny-with-feedback field and Send.
        TestStep.iosTap(.identifier("permission-custom-instructions"))
        TestStep.iosType(text: "sidecar-roundtrip-marker")
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Send"))

        // 8. The sidecar's sendText notification lands the literal text in pane 1.
        TestStep.wait(seconds: 5)
        TestStep.iosScreenshot(label: "ios-sidecar-permission-sent", compare: false)
        TestStep.tmuxCapturePaneContent(target: "${pane1Id}", storeAs: "sidecarPaneContent")
        TestStep.assertStoredContains(
            key: "sidecarPaneContent",
            substring: "sidecar-roundtrip-marker"
        )
    }
}
