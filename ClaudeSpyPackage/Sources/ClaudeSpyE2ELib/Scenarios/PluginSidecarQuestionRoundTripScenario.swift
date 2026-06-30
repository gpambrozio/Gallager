import Foundation

/// E2E scenario: AskUserQuestion (`awaitingReplies`) round-trip via the
/// out-of-process `EchoPluginSidecar`.
///
/// Sibling of `PluginSidecarResponseRoundTripScenario` (which covers the
/// permission form). This is the only scenario that drives the *question* form
/// through the real `SidecarPluginCore` / sidecar-process boundary — every other
/// AskUserQuestion scenario goes through the built-in Claude/Codex hooks. It
/// proves the `AskUserQuestionRequest` (nested under the `awaitingReplies` enum's
/// `_0`) marshals across the stdio transport into a rendered iOS form, and that
/// the chosen answer round-trips back:
///
///   echo-sidecar `awaitingReplies` state → app forwards the open form to iOS →
///   iOS renders `AskUserQuestionResponseView` → user answers + Confirm → iOS
///   submits a structured `AgentResponse.askUserQuestion(answers)` keyed by
///   `requestID` → Mac routes it to `SidecarPluginCore.deliverResponse` → sidecar
///   RPC `deliver_response` → the fixture's `.askUserQuestion` branch fires a
///   `send_text` notification carrying the answered `questionID`s → the host's
///   `sendText` lands that literal text in the bound tmux pane.
///
/// The question id is a distinctive marker so the delivered text is unambiguous
/// in the captured pane content.
public enum PluginSidecarQuestionRoundTripScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Sidecar Question Round Trip",
        tags: ["plugin", "sidecar", "response", "ask-user-question"]
    ) {
        // 1. Stage the echo-sidecar fixture before the app launches.
        TestStep.macStageSidecarFixture(id: "echo-sidecar")

        // 2. Fresh pairing + two tmux panes (stores ${pane1Id} / ${pane2Id}).
        ClaudeSessionsShowScenario.scenario

        // 3. Bind pane 1 to a working sidecar echo session. The pane id IS the
        //    session id so the sidecar's later sendText resolves back to this pane.
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

        // 5. Drive a blocking AskUserQuestion form through the sidecar core. The
        //    open form rides `awaitingReplies`: the synthesized enum nests the
        //    `AskUserQuestionRequest` under `_0` and the correlation id under
        //    `requestID`. `allowsFreeText` enables the "Other" affordance.
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            {
                "sessionID": "${pane1Id}",
                "state": {
                    "awaitingReplies": {
                        "_0": {
                            "questions": [
                                {
                                    "id": "sidecar-aq-marker",
                                    "question": "Sidecar: which topic?",
                                    "header": "Topic",
                                    "options": [
                                        { "id": "o0", "label": "Alpha", "description": "first", "preview": null },
                                        { "id": "o1", "label": "Beta", "description": "second", "preview": null }
                                    ],
                                    "multiSelect": false,
                                    "allowsFreeText": true
                                }
                            ]
                        },
                        "requestID": "sidecar-aq-req-1"
                    }
                },
                "projectPath": "/Users/test/SidecarLab"
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 6. iOS renders the question form.
        TestStep.iosWaitForElement(.labelContains("which topic"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-sidecar-question-form")

        // 7. Answer via the "Other" path (proven flow) → review → Confirm.
        TestStep.iosTap(.labelContains("Open Other"))
        TestStep.wait(seconds: 1)
        TestStep.iosType(text: "sidecar-other")
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Save Other"))

        TestStep.iosWaitForElement(.labelContains("Review Your Answers"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-sidecar-question-summary")
        TestStep.iosTap(.labelContains("Confirm"))
        TestStep.iosWaitForElement(.labelContains("All questions answered"), timeout: 5)

        // 8. The sidecar's deliver_response → send_text lands the answered
        //    questionID ("sidecar-aq-marker") in pane 1.
        TestStep.wait(seconds: 5)
        TestStep.iosScreenshot(label: "ios-sidecar-question-sent", compare: false)
        TestStep.tmuxCapturePaneContent(target: "${pane1Id}", storeAs: "sidecarQuestionPane")
        TestStep.assertStoredContains(
            key: "sidecarQuestionPane",
            substring: "sidecar-aq-marker"
        )
    }
}
