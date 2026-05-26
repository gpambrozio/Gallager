import ClaudeSpyNetworking
import Foundation

/// E2E scenario: Three AskUserQuestion variations driven through the iOS UI in
/// a single paired session.
///
/// Phase 1 — single single-select question, answered via the "Other" path.
/// Phase 2 — single multi-select question with two toggled options + "Other".
/// Phase 3 — three questions (multi-select, single-select, multi-select) to
/// exercise the multi-question flow with the trailing-Enter rule.
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

        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("PermissionRequest"),
                "session_id": .string("e2e-test-session-1"),
                "timestamp": .string("2026-04-25T10:00:00.000000Z"),
                "tool_name": .string("AskUserQuestion"),
                "tool_input": .object([
                    "questions": .array([
                        .object([
                            "question": .string("What is your favorite fruit?"),
                            "header": .string("Fruit"),
                            "options": .array([
                                .object([
                                    "label": .string("Apple"),
                                    "description": .string("Crisp"),
                                ]),
                                .object([
                                    "label": .string("Banana"),
                                    "description": .string("Soft"),
                                ]),
                                .object([
                                    "label": .string("Cherry"),
                                    "description": .string("Tart"),
                                ]),
                            ]),
                            "multiSelect": .bool(false),
                        ]),
                    ]),
                ]),
            ],
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject",
            sessionID: "e2e-test-session-1"
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

        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("PermissionRequest"),
                "session_id": .string("e2e-test-session-1"),
                "timestamp": .string("2026-04-25T10:01:00.000000Z"),
                "tool_name": .string("AskUserQuestion"),
                "tool_input": .object([
                    "questions": .array([
                        .object([
                            "question": .string("Which colors should we use?"),
                            "header": .string("Colors"),
                            "options": .array([
                                .object([
                                    "label": .string("Crimson"),
                                    "description": .string("Warm primary"),
                                ]),
                                .object([
                                    "label": .string("Emerald"),
                                    "description": .string("Cool primary"),
                                ]),
                                .object([
                                    "label": .string("Sapphire"),
                                    "description": .string("Cool primary"),
                                ]),
                                .object([
                                    "label": .string("Amber"),
                                    "description": .string("Warm primary"),
                                ]),
                            ]),
                            "multiSelect": .bool(true),
                        ]),
                    ]),
                ]),
            ],
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject",
            sessionID: "e2e-test-session-1"
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

        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("PermissionRequest"),
                "session_id": .string("e2e-test-session-1"),
                "timestamp": .string("2026-04-25T10:02:00.000000Z"),
                "tool_name": .string("AskUserQuestion"),
                "tool_input": .object([
                    "questions": .array([
                        .object([
                            "question": .string("Which days should we deploy?"),
                            "header": .string("Days"),
                            "options": .array([
                                .object([
                                    "label": .string("Monday"),
                                    "description": .string("Start of week"),
                                ]),
                                .object([
                                    "label": .string("Tuesday"),
                                    "description": .string(""),
                                ]),
                                .object([
                                    "label": .string("Wednesday"),
                                    "description": .string(""),
                                ]),
                                .object([
                                    "label": .string("Thursday"),
                                    "description": .string(""),
                                ]),
                            ]),
                            "multiSelect": .bool(true),
                        ]),
                        .object([
                            "question": .string("Which season fits best?"),
                            "header": .string("Season"),
                            "options": .array([
                                .object([
                                    "label": .string("Spring"),
                                    "description": .string(""),
                                ]),
                                .object([
                                    "label": .string("Summer"),
                                    "description": .string(""),
                                ]),
                                .object([
                                    "label": .string("Autumn"),
                                    "description": .string(""),
                                ]),
                                .object([
                                    "label": .string("Winter"),
                                    "description": .string(""),
                                ]),
                            ]),
                            "multiSelect": .bool(false),
                        ]),
                        .object([
                            "question": .string("Which alert channels should we use?"),
                            "header": .string("Alerts"),
                            "options": .array([
                                .object([
                                    "label": .string("Email"),
                                    "description": .string(""),
                                ]),
                                .object([
                                    "label": .string("Slack"),
                                    "description": .string(""),
                                ]),
                                .object([
                                    "label": .string("Pager"),
                                    "description": .string(""),
                                ]),
                            ]),
                            "multiSelect": .bool(true),
                        ]),
                    ]),
                ]),
            ],
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject",
            sessionID: "e2e-test-session-1"
        )

        TestStep.iosWaitForElement(.labelContains("Which days should we deploy"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p3-q1")
        TestStep.iosTap(.labelContains("Monday"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Wednesday"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Next"))

        TestStep.iosWaitForElement(.labelContains("Which season fits best"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p3-q2")
        TestStep.iosTap(.labelContains("Summer"))

        TestStep.iosWaitForElement(.labelContains("Which alert channels"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-aq-p3-q3")
        TestStep.iosTap(.labelContains("Email"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Slack"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Next"))

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
    }
}
