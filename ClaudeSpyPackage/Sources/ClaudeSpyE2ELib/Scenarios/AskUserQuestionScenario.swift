import Foundation

/// E2E scenario: Three AskUserQuestion variations driven through the iOS UI in
/// a single paired session.
///
/// Phase 1 — single single-select question, answered via the "Other" path.
/// Phase 2 — single multi-select question with two toggled options + "Other".
/// Phase 3 — three questions (multi-select, single-select, multi-select) to
/// exercise the multi-question flow with the trailing-Enter rule. Q1 also
/// browses away and back before committing, proving unsaved multi-select
/// toggles survive arrow navigation as a draft.
/// Phase 4 — four single-select questions answered out of order via the
/// top-right browse arrows (skip → wrap → fill-in), proving non-linear
/// navigation still maps each answer to the right question.
///
/// Right before each Confirm tap a small Python keystroke logger is started
/// in the tmux pane. After Confirm the resulting keystrokes flow through the
/// relay to the Mac and into the pane; the logger records each one and emits
/// a single `SEQUENCE: ...` line that the test asserts against. This proves
/// not only that the iOS UI advances correctly but that the expected bytes
/// actually land in tmux.
///
/// All three phases share one pairing/tmux setup to keep the run cheap.
public enum AskUserQuestionScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Ask User Question",
        tags: ["hooks", "ask-user-question"]
    ) {
        ClaudeSessionsShowScenario.scenario

        TestStep.injectScript(name: "keystroke_logger.py")

        TestStep.iosTap(.labelContains("MyProject"))
        TestStep.iosWaitForElement(.labelContains("Commands"), timeout: 15)

        // ──────────────────────────────────────────────────────────
        // Phase 1: single-select with Other  →  expected: D D D T<Mango> E
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

        TestStep.iosWaitForElement(.labelContains("What is your favorite fruit"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p1-question")

        TestStep.iosTap(.labelContains("Open Other"))
        TestStep.wait(seconds: 1)
        TestStep.iosType(text: "Mango")
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-aq-p1-other-typed")

        TestStep.iosTap(.labelContains("Save Other"))

        TestStep.iosWaitForElement(.labelContains("Review Your Answers"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Other: Mango"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-aq-p1-summary")

        // Start the logger right before Confirm so it's reading stdin when
        // the keystrokes arrive (rather than idling out beforehand).
        Shortcut.tmuxRunCommand(
            target: "session-1:0",
            command: "python3 $TMPDIR/keystroke_logger.py"
        )
        TestStep.wait(seconds: 1)

        TestStep.iosTap(.labelContains("Confirm"))

        TestStep.iosWaitForElement(.labelContains("All questions answered"), timeout: 5)

        // Wait for the keystrokes to flow and the logger to idle out
        // (transit ~delay×keys, plus IDLE_TIMEOUT of 3 s, plus margin).
        TestStep.wait(seconds: 8)
        // Capture screenshot first so the terminal pane (including the
        // logger's SEQUENCE line) is preserved even if the assert fails.
        TestStep.iosScreenshot(label: "ios-aq-p1-done")
        TestStep.tmuxCapturePaneContent(target: "session-1:0", storeAs: "phase1Sequence")
        TestStep.assertStoredContains(
            key: "phase1Sequence",
            substring: "SEQUENCE: D D D T<Mango> E"
        )

        // ──────────────────────────────────────────────────────────
        // Phase 2: multi-select with options + Other
        // expected: E D D E D D T<Onyx> S D E E
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

        TestStep.iosWaitForElement(.labelContains("Other: Onyx"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-aq-p2-other-saved")

        TestStep.iosTap(.labelContains("Next"))

        TestStep.iosWaitForElement(.labelContains("Review Your Answers"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Crimson"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Sapphire"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Other: Onyx"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-aq-p2-summary")

        Shortcut.tmuxRunCommand(
            target: "session-1:0",
            command: "python3 $TMPDIR/keystroke_logger.py"
        )
        TestStep.wait(seconds: 1)

        TestStep.iosTap(.labelContains("Confirm"))

        TestStep.iosWaitForElement(.labelContains("All questions answered"), timeout: 5)

        TestStep.wait(seconds: 8)
        TestStep.iosScreenshot(label: "ios-aq-p2-done")
        TestStep.tmuxCapturePaneContent(target: "session-1:0", storeAs: "phase2Sequence")
        TestStep.assertStoredContains(
            key: "phase2Sequence",
            substring: "SEQUENCE: E D D E D D T<Onyx> S D E E"
        )

        // ──────────────────────────────────────────────────────────
        // Phase 3: 2 multi-select + 1 single-select
        // expected: E D D E R D E E D E R E
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

        TestStep.iosWaitForElement(.labelContains("Which days should we deploy"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p3-q1")
        TestStep.iosTap(.labelContains("Monday"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Wednesday"))
        TestStep.wait(seconds: 1)
        // Browse away and back before committing: the unsaved toggles must
        // survive as a draft. The multi-select "Next" button below only
        // renders while something is selected, so its tap doubles as the
        // draft-restore assertion.
        TestStep.iosTap(.label("Next question"))
        TestStep.iosWaitForElement(.labelContains("Which season fits best"), timeout: 10)
        TestStep.iosTap(.label("Previous question"))
        TestStep.iosWaitForElement(.labelContains("Which days should we deploy"), timeout: 10)
        // Exact match: the browse arrow exposes "Next question", which a
        // substring match on "Next" would hit first.
        TestStep.iosTap(.label("Next"))

        TestStep.iosWaitForElement(.labelContains("Which season fits best"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p3-q2")
        TestStep.iosTap(.labelContains("Summer"))

        TestStep.iosWaitForElement(.labelContains("Which alert channels"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p3-q3")
        TestStep.iosTap(.labelContains("Email"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Slack"))
        TestStep.wait(seconds: 1)
        // Exact match — see the note on the first multi-select "Next" above.
        TestStep.iosTap(.label("Next"))

        TestStep.iosWaitForElement(.labelContains("Review Your Answers"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Monday"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Wednesday"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Summer"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Email"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Slack"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-aq-p3-summary")

        Shortcut.tmuxRunCommand(
            target: "session-1:0",
            command: "python3 $TMPDIR/keystroke_logger.py"
        )
        TestStep.wait(seconds: 1)

        TestStep.iosTap(.labelContains("Confirm"))

        TestStep.iosWaitForElement(.labelContains("All questions answered"), timeout: 5)

        TestStep.wait(seconds: 8)
        TestStep.iosScreenshot(label: "ios-aq-p3-done")
        TestStep.tmuxCapturePaneContent(target: "session-1:0", storeAs: "phase3Sequence")
        TestStep.assertStoredContains(
            key: "phase3Sequence",
            substring: "SEQUENCE: E D D E R D E E D E R E"
        )

        // ──────────────────────────────────────────────────────────
        // Phase 4: four single-select questions answered out of order via
        // the top-right browse arrows. The user skips Q1, answers Q2, skips
        // Q3, answers Q4 (wrapping back to the skipped Q1), answers Q1
        // (advancing to the still-unanswered Q3), then answers Q3 → summary.
        // Final per-question picks: Q1=Banana(1) Q2=Red(0) Q3=Dog(1)
        // Q4=Two(1). Keystrokes are emitted in question order regardless of
        // the answering order, so: D E · E · D E · D E · E (trailing).
        // expected: D E E D E D E E
        // ──────────────────────────────────────────────────────────

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-test-session-1",
                "timestamp": "2026-04-25T10:03:00.000000Z",
                "tool_name": "AskUserQuestion",
                "tool_input": {
                    "questions": [
                        {
                            "question": "What is your favorite fruit?",
                            "header": "Fruit",
                            "options": [
                                {"label": "Apple", "description": ""},
                                {"label": "Banana", "description": ""}
                            ],
                            "multiSelect": false
                        },
                        {
                            "question": "What is your favorite color?",
                            "header": "Color",
                            "options": [
                                {"label": "Red", "description": ""},
                                {"label": "Blue", "description": ""}
                            ],
                            "multiSelect": false
                        },
                        {
                            "question": "What is your favorite animal?",
                            "header": "Animal",
                            "options": [
                                {"label": "Cat", "description": ""},
                                {"label": "Dog", "description": ""}
                            ],
                            "multiSelect": false
                        },
                        {
                            "question": "What is your favorite number?",
                            "header": "Number",
                            "options": [
                                {"label": "One", "description": ""},
                                {"label": "Two", "description": ""}
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

        // Q1 is shown first. Skip it without answering via the right arrow.
        TestStep.iosWaitForElement(.labelContains("What is your favorite fruit"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p4-q1")
        TestStep.iosTap(.label("Next question"))

        // Now on Q2 (we skipped Q1 without answering). Answer it; a
        // single-select answer auto-advances to the next unanswered (Q3).
        TestStep.iosWaitForElement(.labelContains("What is your favorite color"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p4-skipped-to-q2")
        TestStep.iosTap(.labelContains("Red"))

        // On Q3. Skip it via the right arrow to reach the last question, Q4.
        TestStep.iosWaitForElement(.labelContains("What is your favorite animal"), timeout: 10)
        TestStep.iosTap(.label("Next question"))

        // On the last question Q4. Answering it wraps back to the first
        // still-unanswered question, Q1.
        TestStep.iosWaitForElement(.labelContains("What is your favorite number"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p4-skipped-to-q4")
        TestStep.iosTap(.labelContains("Two"))

        // Wrapped back to Q1. Answering it advances to the remaining
        // unanswered question, Q3 (Q2 is already answered).
        TestStep.iosWaitForElement(.labelContains("What is your favorite fruit"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p4-wrapped-to-q1")
        TestStep.iosTap(.labelContains("Banana"))

        // Back on Q3 — the last unanswered question. Answering it completes
        // the set and shows the summary.
        TestStep.iosWaitForElement(.labelContains("What is your favorite animal"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p4-back-to-q3")
        TestStep.iosTap(.labelContains("Dog"))

        TestStep.iosWaitForElement(.labelContains("Review Your Answers"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Banana"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Red"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Dog"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Two"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-aq-p4-summary")

        Shortcut.tmuxRunCommand(
            target: "session-1:0",
            command: "python3 $TMPDIR/keystroke_logger.py"
        )
        TestStep.wait(seconds: 1)

        TestStep.iosTap(.labelContains("Confirm"))

        TestStep.iosWaitForElement(.labelContains("All questions answered"), timeout: 5)

        TestStep.wait(seconds: 8)
        TestStep.iosScreenshot(label: "ios-aq-p4-done")
        TestStep.tmuxCapturePaneContent(target: "session-1:0", storeAs: "phase4Sequence")
        TestStep.assertStoredContains(
            key: "phase4Sequence",
            substring: "SEQUENCE: D E E D E D E E"
        )
    }
}
