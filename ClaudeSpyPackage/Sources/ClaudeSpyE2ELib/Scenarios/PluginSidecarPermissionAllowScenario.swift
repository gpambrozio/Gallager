import Foundation

/// E2E scenario: permission **allow** round-trip via the out-of-process
/// `EchoPluginSidecar`.
///
/// `PluginSidecarResponseRoundTripScenario` already covers the deny-with-feedback
/// branch (which routes through `send_text`). This covers the *allow* branch,
/// which is the one sidecar path that exercises `send_keys` with a `.text` key —
/// the surface most prone to a wire-encoding mistake (`TmuxKey.text` must encode
/// as `{"text": {"_0": "1"}}`, not a bare string):
///
///   echo-sidecar `awaitingPermission` state → app forwards the open form to iOS
///   → iOS renders `PermissionRequestResponseView` → user taps Accept → iOS
///   submits `AgentResponse.permission(.allow, appliedSuggestionID: nil)` → Mac
///   routes it to `SidecarPluginCore.deliverResponse` → sidecar RPC
///   `deliver_response` → the fixture's `.permission(.allow)` branch fires a
///   `send_keys [.text("1")]` notification → the keystroke lands in the pane.
///
/// A keystroke logger in the pane records the byte; `T<1>` is the logger's token
/// for the literal text key "1".
public enum PluginSidecarPermissionAllowScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Sidecar Permission Allow Round Trip",
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

        // 6. Drive a blocking permission form through the sidecar core. No custom
        //    instructions / suggestions — we take the plain Accept (allow) path.
        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            {
                "sessionID": "${pane1Id}",
                "state": {
                    "awaitingPermission": {
                        "_0": {
                            "title": "Sidecar wants to run a command",
                            "description": "sidecar permission allow",
                            "isAutoApprovable": false,
                            "suggestions": [],
                            "allowsCustomInstructions": false
                        },
                        "requestID": "sidecar-allow-req-1"
                    }
                },
                "projectPath": "/Users/test/SidecarLab"
            }
            """,
            tmuxPane: "${pane1Id}"
        )

        // 7. iOS renders the permission form.
        TestStep.iosWaitForElement(.labelContains("Accept"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-sidecar-permission-allow-form")

        // 8. Start the logger right before Accept so it's reading stdin when the
        //    keystroke arrives.
        Shortcut.tmuxRunCommand(
            target: "session-1:0",
            command: "python3 $TMPDIR/keystroke_logger.py"
        )
        TestStep.wait(seconds: 1)

        // 9. Accept → the sidecar's send_keys [.text("1")] reaches the pane.
        TestStep.iosTap(.label("Accept"))

        // 10. Wait for the keystroke to flow and the logger to idle out.
        TestStep.wait(seconds: 8)
        TestStep.iosScreenshot(label: "ios-sidecar-permission-allowed", compare: false)
        TestStep.tmuxCapturePaneContent(target: "session-1:0", storeAs: "sidecarAllowSequence")
        TestStep.assertStoredContains(
            key: "sidecarAllowSequence",
            substring: "SEQUENCE: T<1>"
        )
    }
}
