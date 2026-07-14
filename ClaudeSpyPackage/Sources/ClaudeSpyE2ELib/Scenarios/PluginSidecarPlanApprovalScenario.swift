import Foundation

/// E2E scenario: plan-approval (`awaitingPlanApproval`) round-trip via the
/// out-of-process `EchoPluginSidecar`.
///
/// The only scenario that drives the *plan* form through the real
/// `SidecarPluginCore` / sidecar-process boundary (the other plan-approval
/// coverage is Claude/Codex hooks). It proves the `ApprovePlanRequest` (nested
/// under the `awaitingPlanApproval` enum's `_0`) marshals across the stdio
/// transport into a rendered iOS form, and that an Approve round-trips back:
///
///   echo-sidecar `awaitingPlanApproval` state → app forwards the open form to
///   iOS → iOS renders `ExitPlanModeResponseView` → user taps Approve → iOS
///   submits `AgentResponse.approvePlan(.approve, editedPlan: nil)` → Mac routes
///   it to `SidecarPluginCore.deliverResponse` → sidecar RPC `deliver_response` →
///   the fixture's `.approvePlan(.approve)` branch (no edited plan) fires a
///   `send_keys [.text("3")]` notification → the keystroke lands in the pane.
///
/// A keystroke logger in the pane records the byte so the test asserts the
/// `send_keys` path (not just that the form rendered). `T<3>` is the logger's
/// token for the literal text key "3".
public enum PluginSidecarPlanApprovalScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Sidecar Plan Approval Round Trip",
        tags: ["plugin", "sidecar", "response"]
    ) {
        // 1. Stage the echo-sidecar fixture before the app launches.
        TestStep.macStageSidecarFixture(id: "echo-sidecar")

        // 2. Fresh pairing + two tmux panes (stores ${pane1Id} / ${pane2Id}).
        ClaudeSessionsShowScenario.scenario

        // 3. The keystroke logger Python helper (asserts the delivered byte).
        TestStep.injectScript(name: "keystroke_logger.py")

        // 4. Bind pane 1 to a working sidecar echo session.
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

        // 5. Open the sidecar session on iOS so the response form can render.
        TestStep.iosWaitForElement(.labelContains("SidecarLab"), timeout: 15)
        TestStep.iosTap(.labelContains("SidecarLab"))
        TestStep.iosWaitForElement(.labelContains("Commands"), timeout: 15)

        // 6. Drive a blocking plan-approval form through the sidecar core. The
        //    open form rides `awaitingPlanApproval`: the synthesized enum nests
        //    the `ApprovePlanRequest` under `_0` and the correlation id under
        //    `requestID`.
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            {
                "sessionID": "${pane1Id}",
                "state": {
                    "awaitingPlanApproval": {
                        "_0": {
                            "title": "Sidecar proposes a plan",
                            "plan": "1. Stage the fixture\\n2. Round-trip the approval",
                            "allowsEdit": false
                        },
                        "requestID": "sidecar-plan-req-1"
                    }
                },
                "projectPath": "/Users/test/SidecarLab"
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 7. iOS renders the plan-approval form.
        TestStep.iosWaitForElement(.labelContains("Approve"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-sidecar-plan-form")

        // 8. Start the logger right before Approve so it's reading stdin when the
        //    keystroke arrives.
        Shortcut.tmuxRunCommand(
            target: "session-1:0",
            command: "python3 $TMPDIR/keystroke_logger.py"
        )
        TestStep.wait(seconds: 1)

        // 9. Approve → the sidecar's send_keys [.text("3")] reaches the pane.
        TestStep.iosTap(.labelContains("Approve"))

        // 10. Wait for the keystroke to flow and the logger to idle out.
        TestStep.wait(seconds: 8)
        TestStep.iosScreenshot(label: "ios-sidecar-plan-approved", compare: false)
        TestStep.tmuxCapturePaneContent(target: "session-1:0", storeAs: "sidecarPlanSequence")
        TestStep.assertStoredContains(
            key: "sidecarPlanSequence",
            substring: "SEQUENCE: T<3>"
        )
    }
}
