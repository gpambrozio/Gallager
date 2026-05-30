import Foundation

/// E2E scenario: the response-form round-trip via the reference `EchoPluginCore`
/// (spec §17.3). Asserts the full loop:
///
///   echo `prompt` responseRequest frame → app forwards `agent_response_request`
///   to iOS → iOS renders the closed `PromptView` → user types + taps Send → iOS
///   submits a structured `AgentResponse.prompt(text)` → Mac matches the request id
///   and calls `EchoPluginCore.deliverResponse` → echo's `.prompt` branch calls
///   `host.sendText` → the text lands in the bound tmux pane.
///
/// The echo `sessionID` is the tmux pane id, so the host's `sendText` resolves
/// the session straight back to that pane (`resolvePluginPaneTarget`) and the
/// submitted text is observable via `capture-pane`. This proves `deliverResponse`
/// reached the core AND that the core drove delivery (the spec's requirement).
public enum EchoResponseRoundTripScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Echo Response Round Trip",
        tags: ["plugin", "ingress", "echo", "response"]
    ) {
        // Fresh pairing + two tmux panes (stores ${pane1Id} / ${pane2Id}).
        ClaudeSessionsShowScenario.scenario

        // 1. Bind pane 1 to an echo session. Use the pane id AS the session id so
        //    the host's later sendText resolves the session back to this pane.
        TestStep.macSendHookEvent(
            pluginID: "echo",
            json: """
            {
                "sessionID": "${pane1Id}",
                "working": true,
                "attention": false,
                "projectPath": "/Users/test/EchoLab"
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 2. Open the echo session on iOS so the response form can render inline.
        TestStep.iosWaitForElement(.labelContains("EchoLab"), timeout: 10)
        TestStep.iosTap(.labelContains("EchoLab"))
        TestStep.iosWaitForElement(.labelContains("Commands"), timeout: 15)

        // 3. Drive a prompt response request through the echo core. The nested
        //    `request` is the synthesized `AgentResponseRequest.prompt` encoding
        //    (`{ "prompt": { "_0": { ... } } }`). `requestID` is what the Mac
        //    correlates the iOS submission against.
        TestStep.macSendHookEvent(
            pluginID: "echo",
            json: """
            {
                "sessionID": "${pane1Id}",
                "working": false,
                "attention": true,
                "projectPath": "/Users/test/EchoLab",
                "responseRequest": {
                    "requestID": "echo-prompt-req-1",
                    "request": {
                        "prompt": {
                            "_0": {
                                "title": "Send a message to Echo",
                                "placeholder": "Type a message for echo"
                            }
                        }
                    }
                }
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 4. iOS renders the PromptView (its placeholder is the TextField's a11y
        //    label) — confirming the request reached the viewer.
        TestStep.iosWaitForElement(.labelContains("Type a message for echo"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-echo-prompt-form")

        // 5. Type the message and Send. iOS submits AgentResponse.prompt(text);
        //    the Mac routes it to EchoPluginCore.deliverResponse → host.sendText.
        TestStep.iosTap(.labelContains("Type a message for echo"))
        TestStep.iosType(text: "echo-roundtrip-marker")
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Send"))

        // 6. The echo core's sendText lands the literal text in pane 1. Capture
        //    the pane and assert the marker arrived — the delivery half of the
        //    round-trip.
        TestStep.wait(seconds: 5)
        TestStep.iosScreenshot(label: "ios-echo-prompt-sent")
        TestStep.tmuxCapturePaneContent(target: "${pane1Id}", storeAs: "echoPaneContent")
        TestStep.assertStoredContains(
            key: "echoPaneContent",
            substring: "echo-roundtrip-marker"
        )
    }
}
