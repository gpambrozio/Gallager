import Foundation

/// E2E scenario: Three AskUserQuestion variations driven through the iOS UI in
/// a single paired session.
///
/// Phase 1 — single single-select question, answered via the "Other" path.
/// Phase 2 — single multi-select question with two toggled options + "Other".
/// Phase 3 — three questions (multi-select, single-select, multi-select) to
/// exercise the multi-question flow with the trailing-Enter rule.
///
/// All three phases share one pairing/tmux setup to keep the run cheap.
public enum AskUserQuestionScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Ask User Question",
        tags: ["hooks", "ask-user-question"]
    ) {
        // Fresh pairing + tmux + SessionStart hook on session-1
        ClaudeSessionsShowScenario.scenario

        // Open the session detail view once; subsequent phases reuse it.
        TestStep.iosTap(.labelContains("MyProject"))
        TestStep.wait(seconds: 5)
        TestStep.iosWaitForElement(.labelContains("Commands"), timeout: 15)

        // ──────────────────────────────────────────────────────────
        // Phase 1: single-select with Other
        // ──────────────────────────────────────────────────────────

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-test-session-1",
                "timestamp": "2026-04-25T10:00:00.000000Z",
                "tool_name": "AskUserQuestion",
                "tool_input": {
                    "questions": [
                        {
                            "question": "What is your favorite fruit?",
                            "header": "Fruit",
                            "options": [
                                {"label": "Apple", "description": "Crisp"},
                                {"label": "Banana", "description": "Soft"},
                                {"label": "Cherry", "description": "Tart"}
                            ],
                            "multiSelect": false
                        }
                    ]
                }
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )
        TestStep.wait(seconds: 3)

        TestStep.iosWaitForElement(.labelContains("What is your favorite fruit"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p1-question")

        TestStep.iosTap(.labelContains("Open Other"))
        TestStep.wait(seconds: 1)
        TestStep.iosType(text: "Mango")
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-aq-p1-other-typed")

        TestStep.iosTap(.labelContains("Save Other"))
        TestStep.wait(seconds: 2)

        TestStep.iosWaitForElement(.labelContains("Review Your Answers"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Other: Mango"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-aq-p1-summary")

        TestStep.iosTap(.labelContains("Confirm"))
        TestStep.wait(seconds: 2)

        TestStep.iosWaitForElement(.labelContains("All questions answered"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-aq-p1-done")

        // ──────────────────────────────────────────────────────────
        // Phase 2: multi-select with options + Other
        // ──────────────────────────────────────────────────────────

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-test-session-1",
                "timestamp": "2026-04-25T10:01:00.000000Z",
                "tool_name": "AskUserQuestion",
                "tool_input": {
                    "questions": [
                        {
                            "question": "Which colors should we use?",
                            "header": "Colors",
                            "options": [
                                {"label": "Crimson", "description": "Warm primary"},
                                {"label": "Emerald", "description": "Cool primary"},
                                {"label": "Sapphire", "description": "Cool primary"},
                                {"label": "Amber", "description": "Warm primary"}
                            ],
                            "multiSelect": true
                        }
                    ]
                }
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )
        TestStep.wait(seconds: 3)

        TestStep.iosWaitForElement(.labelContains("Which colors should we use"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p2-question")

        TestStep.iosTap(.labelContains("Crimson"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Sapphire"))
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-aq-p2-toggled")

        TestStep.iosTap(.labelContains("Open Other"))
        TestStep.wait(seconds: 1)
        TestStep.iosType(text: "Onyx")
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Save Other"))
        TestStep.wait(seconds: 2)

        TestStep.iosWaitForElement(.labelContains("Other: Onyx"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-aq-p2-other-saved")

        TestStep.iosTap(.labelContains("Next"))
        TestStep.wait(seconds: 2)

        TestStep.iosWaitForElement(.labelContains("Review Your Answers"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Crimson"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Sapphire"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Other: Onyx"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-aq-p2-summary")

        TestStep.iosTap(.labelContains("Confirm"))
        TestStep.wait(seconds: 2)

        TestStep.iosWaitForElement(.labelContains("All questions answered"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-aq-p2-done")

        // ──────────────────────────────────────────────────────────
        // Phase 3: 2 multi-select + 1 single-select
        // ──────────────────────────────────────────────────────────

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-test-session-1",
                "timestamp": "2026-04-25T10:02:00.000000Z",
                "tool_name": "AskUserQuestion",
                "tool_input": {
                    "questions": [
                        {
                            "question": "Which days should we deploy?",
                            "header": "Days",
                            "options": [
                                {"label": "Monday", "description": "Start of week"},
                                {"label": "Tuesday", "description": ""},
                                {"label": "Wednesday", "description": ""},
                                {"label": "Thursday", "description": ""}
                            ],
                            "multiSelect": true
                        },
                        {
                            "question": "Which season fits best?",
                            "header": "Season",
                            "options": [
                                {"label": "Spring", "description": ""},
                                {"label": "Summer", "description": ""},
                                {"label": "Autumn", "description": ""},
                                {"label": "Winter", "description": ""}
                            ],
                            "multiSelect": false
                        },
                        {
                            "question": "Which alert channels should we use?",
                            "header": "Alerts",
                            "options": [
                                {"label": "Email", "description": ""},
                                {"label": "Slack", "description": ""},
                                {"label": "Pager", "description": ""}
                            ],
                            "multiSelect": true
                        }
                    ]
                }
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )
        TestStep.wait(seconds: 3)

        TestStep.iosWaitForElement(.labelContains("Which days should we deploy"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p3-q1")
        TestStep.iosTap(.labelContains("Monday"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Wednesday"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Next"))
        TestStep.wait(seconds: 2)

        TestStep.iosWaitForElement(.labelContains("Which season fits best"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p3-q2")
        TestStep.iosTap(.labelContains("Summer"))
        TestStep.wait(seconds: 2)

        TestStep.iosWaitForElement(.labelContains("Which alert channels"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p3-q3")
        TestStep.iosTap(.labelContains("Email"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Slack"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Next"))
        TestStep.wait(seconds: 2)

        TestStep.iosWaitForElement(.labelContains("Review Your Answers"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Monday"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Wednesday"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Summer"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Email"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Slack"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-aq-p3-summary")

        TestStep.iosTap(.labelContains("Confirm"))
        TestStep.wait(seconds: 2)

        TestStep.iosWaitForElement(.labelContains("All questions answered"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-aq-p3-done")
    }
}
