import ClaudeSpyNetworking
import Foundation

/// E2E scenario: AskUserQuestion round-trip via plugin (Spec §15.3 #7).
///
/// Drives the full structured-answer pipeline:
/// 1. Echo emits an `askUserQuestion` response request with two
///    questions: a single-select fruit picker and a multi-select color
///    picker with `allow_free_text: true`.
/// 2. iOS walks both questions in `AskUserQuestionResponseView`: tap
///    "Apple" on the first, toggle "Red" + "Other(Onyx)" on the second,
///    Confirm.
/// 3. The Mac forwards the assembled `AskUserQuestionResponse` back to
///    Echo's `handleDeliverResponse`, which:
///    - Writes the JSON to `${state_dir}/responses/echo-req-1.json`.
///    - Replays the embedded `_delivery_script` (one `send_text`
///      followed by one `send_keys`) so the test can also assert on the
///      sidecar→Mac `send_text`/`send_keys` callbacks — the keystroke
///      pipeline that closes the loop with the host agent.
/// 4. Scenario reads the response file and asserts on the answers shape.
public enum PluginAskUserQuestionRoundTripScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Ask User Question Round Trip",
        tags: ["plugins", "echo", "ask-user-question"]
    ) {
        FreshPairingScenario.scenario

        TestStep.macSpawnSidecar(
            pluginID: "echo",
            fixtureSourcePath: URL(fileURLWithPath: "Fixtures/EchoPlugin"),
            instance: 0
        )

        TestStep.tmuxCreateSession(name: "echo-auq", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "echo-auq:0.0", storeAs: "paneId")

        // 1. Send the askUserQuestion request with two questions and an
        //    embedded `_delivery_script` so `handleDeliverResponse` will
        //    issue a `send_text` + `send_keys` callback after the answer
        //    arrives back.
        TestStep.macSendRawHookPayload(
            pluginID: "echo",
            json: .object([
                "_test": .string("request_ask_user_question"),
                "session_id": .string("echo-auq-session"),
                "questions": .array([
                    .object([
                        "prompt": .string("What is your favorite fruit?"),
                        "allow_multiple": .bool(false),
                        "allow_free_text": .bool(false),
                        "options": .array([
                            .object([
                                "label": .string("Apple"),
                                "detail": .string("Crisp"),
                            ]),
                            .object([
                                "label": .string("Banana"),
                                "detail": .string("Soft"),
                            ]),
                        ]),
                    ]),
                    .object([
                        "prompt": .string("Which colors should we use?"),
                        "allow_multiple": .bool(true),
                        "allow_free_text": .bool(true),
                        "options": .array([
                            .object([
                                "label": .string("Red"),
                                "detail": .string("Warm"),
                            ]),
                            .object([
                                "label": .string("Blue"),
                                "detail": .string("Cool"),
                            ]),
                        ]),
                    ]),
                ]),
                "_delivery_script": .array([
                    .object([
                        "type": .string("send_text"),
                        "text": .string("echo-auq-confirmed"),
                    ]),
                    .object([
                        "type": .string("send_keys"),
                        "keys": .array([.string("Enter")]),
                    ]),
                ]),
            ]),
            env: ["TMUX_PANE": "${paneId}"]
        )

        // 2a. Q1 — single-select. Pick Apple.
        TestStep.iosWaitForElement(.valueContains("Attention"), timeout: 15)
        TestStep.iosTap(.valueContains("Attention"))
        TestStep.iosWaitForElement(.labelContains("What is your favorite fruit"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-auq-q1")
        TestStep.iosTap(.labelContains("Apple"))

        // 2b. Q2 — multi-select with "Other". Tap Red, then open + save
        //     "Other" with "Onyx".
        TestStep.iosWaitForElement(.labelContains("Which colors should we use"), timeout: 10)
        TestStep.iosTap(.labelContains("Red"))
        TestStep.iosScreenshot(label: "ios-auq-q2-toggled")
        TestStep.iosTap(.labelContains("Open Other"))
        TestStep.wait(seconds: 1)
        TestStep.iosType(text: "Onyx")
        TestStep.iosTap(.labelContains("Save Other"))
        TestStep.iosWaitForElement(.labelContains("Other: Onyx"), timeout: 5)
        TestStep.iosTap(.labelContains("Next"))

        // 2c. Review screen + Confirm.
        TestStep.iosWaitForElement(.labelContains("Review Your Answers"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-auq-review")
        TestStep.iosTap(.labelContains("Confirm"))
        // After Confirm the response form dismisses. The strongest assertion
        // of the round-trip is the response file written by EchoSidecar
        // (asserted in steps below). Let the form transition settle, then
        // screenshot.
        TestStep.wait(seconds: 1.5)
        TestStep.iosScreenshot(label: "ios-auq-done")

        // 3. EchoSidecar writes the JSON to disk before running the
        //    `_delivery_script`. Poll for the file to land.
        TestStep.waitForFileContains(
            path: "${echoResponsesDir}/echo-req-1.json",
            substring: "ask_user_question",
            storeAs: "auqResponseJSON",
            timeout: 10
        )

        // 4. The structured answer should round-trip intact. Each question
        //    answer has a `selected_option_indices` array (snake_case) and
        //    optional `free_text`. Apple is index 0; Red+Other is index 0
        //    plus the "Onyx" free_text.
        TestStep.assertStoredContains(
            key: "auqResponseJSON",
            substring: "\"type\":\"ask_user_question\""
        )
        TestStep.assertStoredContains(
            key: "auqResponseJSON",
            substring: "Onyx"
        )
        TestStep.assertStoredContains(
            key: "auqResponseJSON",
            substring: "\"selected_option_indices\":[0]"
        )
    }
}
