import Foundation

/// E2E scenario: the response-form round-trip via the reference `EchoPluginCore`
/// (spec §17.3). Drives a blocking permission form end-to-end and proves the core
/// delivered the answer:
///
///   echo `awaitingPermission` state → app forwards the open form to iOS → iOS
///   renders `PermissionRequestResponseView` → user types deny-with-feedback + Send
///   → iOS submits a structured `AgentResponse.permission(.denyWithFeedback)` keyed
///   by `requestID` → Mac matches the request id and calls
///   `EchoPluginCore.deliverResponse` → echo's `.denyWithFeedback` branch calls
///   `host.sendText` → the text lands in the bound tmux pane.
///
/// In the agent-blind `AgentState` model the open form rides the `awaiting*` cases
/// (there is no standalone `.prompt` state), so this exercises the structured
/// `deliverResponse` path rather than the free-text reply-after-stop keystroke
/// pipeline. The echo `sessionID` is the tmux pane id, so the host's `sendText`
/// resolves the session straight back to that pane (`resolvePluginPaneTarget`) and
/// the submitted text is observable via `capture-pane`. This proves
/// `deliverResponse` reached the core AND that the core drove delivery (the spec's
/// requirement).
public enum EchoResponseRoundTripScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Echo Response Round Trip",
        tags: ["plugin", "ingress", "echo", "response"]
    ) {
        // Fresh pairing + two tmux panes (stores ${pane1Id} / ${pane2Id}).
        ClaudeSessionsShowScenario.scenario

        // 1. Bind pane 1 to a working echo session. Use the pane id AS the session
        //    id so the host's later sendText resolves the session back to this pane.
        TestStep.macSendHookEvent(
            pluginID: "echo",
            json: """
            {
                "sessionID": "${pane1Id}",
                "state": { "working": {} },
                "projectPath": "/Users/test/EchoLab"
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 2. Open the echo session on iOS so the response form can render inline.
        TestStep.iosWaitForElement(.labelContains("EchoLab"), timeout: 10)
        TestStep.iosTap(.labelContains("EchoLab"))
        TestStep.iosWaitForElement(.labelContains("Commands"), timeout: 15)

        // 3. Drive a blocking permission form through the echo core. The open form
        //    rides the `awaitingPermission` AgentState — the synthesized enum
        //    encoding nests the `PermissionRequest` under `_0` and the correlation
        //    id under `requestID`. `allowsCustomInstructions` enables the
        //    deny-with-feedback free-text field.
        TestStep.macSendHookEvent(
            pluginID: "echo",
            json: """
            {
                "sessionID": "${pane1Id}",
                "state": {
                    "awaitingPermission": {
                        "_0": {
                            "title": "Echo wants to run a command",
                            "description": "echo round-trip",
                            "isAutoApprovable": false,
                            "suggestions": [],
                            "allowsCustomInstructions": true
                        },
                        "requestID": "echo-perm-req-1"
                    }
                },
                "projectPath": "/Users/test/EchoLab"
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 4. iOS renders the permission form: the Accept button and the
        //    deny-with-feedback field (its stable identifier) confirm the open form
        //    reached the viewer.
        TestStep.iosWaitForElement(.labelContains("Accept"), timeout: 10)
        TestStep.iosWaitForElement(.identifier("permission-custom-instructions"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-echo-permission-form")

        // 5. Type the marker into the deny-with-feedback field and Send. iOS submits
        //    AgentResponse.permission(.denyWithFeedback(text)); the Mac routes it to
        //    EchoPluginCore.deliverResponse → host.sendText.
        TestStep.iosTap(.identifier("permission-custom-instructions"))
        TestStep.iosType(text: "echo-roundtrip-marker")
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Send"))

        // 6. The echo core's sendText lands the literal text in pane 1. Capture the
        //    pane and assert the marker arrived — the delivery half of the round-trip.
        TestStep.wait(seconds: 5)
        TestStep.iosScreenshot(label: "ios-echo-permission-sent", compare: false)
        TestStep.tmuxCapturePaneContent(target: "${pane1Id}", storeAs: "echoPaneContent")
        TestStep.assertStoredContains(
            key: "echoPaneContent",
            substring: "echo-roundtrip-marker"
        )
    }
}
