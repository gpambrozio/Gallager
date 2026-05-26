import ClaudeSpyNetworking
import Foundation

/// E2E scenario: Claude session replies persist between screens
///
/// Builds on the Claude Sessions Show scenario. Verifies that user responses
/// to hook events (AskUserQuestion, PermissionRequest, ExitPlanMode) persist
/// when navigating away from and back to the session terminal view.
public enum ClaudeSessionRepliesPersistScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Claude Session Replies Persist",
        tags: ["hooks", "sessions", "persistence"]
    ) {
        // ──────────────────────────────────────────────────────────
        // Phase 0: Setup — fresh pairing + tmux + SessionStart hook
        // ──────────────────────────────────────────────────────────
        ClaudeSessionsShowScenario.scenario

        // Tap the session row to open the terminal view
        TestStep.iosTap(.labelContains("MyProject"))

        // Verify the terminal view loaded by checking for the Commands menu button
        TestStep.iosWaitForElement(.labelContains("Commands"), timeout: 15)

        // ──────────────────────────────────────────────────────────
        // Phase 0.5: Verify prompt text box and persistence
        // ──────────────────────────────────────────────────────────

        // Verify the prompt text box is shown (PromptView for SessionStart)
        TestStep.iosWaitForElement(.labelContains("Send a message to Claude"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("Send"), timeout: 5)

        // Enter some text and submit
        TestStep.iosTap(.labelContains("Send a message to Claude"))
        TestStep.iosType(text: "Hello from e2e test")
        TestStep.iosScreenshot(label: "ios-prompt-filled")
        TestStep.iosTap(.labelContains("Send"))

        // Verify the prompt submitted feedback is showing after submission
        TestStep.iosWaitForElement(.labelContains("Prompt submitted"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-prompt-submitted")

        // Navigate back to session list
        TestStep.iosTap(.labelContains("Sessions"))
        TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 5)

        // Re-enter session
        TestStep.iosTap(.labelContains("MyProject"))

        // Verify the prompt submitted feedback persists after navigating back
        TestStep.iosWaitForElement(.labelContains("Prompt submitted"), timeout: 10)
        // Wait for the terminal to finish (re)connecting — the baseline
        // captures the connected state, so the screenshot must not race
        // the "Connecting to terminal..." placeholder.
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting to terminal"), timeout: 10)
        // Settle wait for the terminal view's push transition.
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-prompt-persists")

        // ──────────────────────────────────────────────────────────
        // Phase 1: AskUserQuestion with 2 questions
        // ──────────────────────────────────────────────────────────

        // Send AskUserQuestion hook (replaces PromptView with question UI)
        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("PermissionRequest"),
                "session_id": .string("e2e-test-session-1"),
                "timestamp": .string("2026-02-14T10:01:00.000000Z"),
                "tool_name": .string("AskUserQuestion"),
                "tool_input": .object([
                    "questions": .array([
                        .object([
                            "question": .string("Which database should we use?"),
                            "header": .string("Database"),
                            "options": .array([
                                .object([
                                    "label": .string("PostgreSQL"),
                                    "description": .string("Relational database"),
                                ]),
                                .object([
                                    "label": .string("MongoDB"),
                                    "description": .string("Document database"),
                                ]),
                            ]),
                            "multiSelect": .bool(false),
                        ]),
                        .object([
                            "question": .string("Which caching strategy?"),
                            "header": .string("Caching"),
                            "options": .array([
                                .object([
                                    "label": .string("Redis"),
                                    "description": .string("In-memory cache"),
                                ]),
                                .object([
                                    "label": .string("Memcached"),
                                    "description": .string("Distributed cache"),
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

        // Verify question 1 shows
        TestStep.iosWaitForElement(.labelContains("Which database"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-question-1")

        // Tap first option (single-select auto-advances to question 2)
        TestStep.iosTap(.labelContains("PostgreSQL"))

        // Verify question 2 shows
        TestStep.iosWaitForElement(.labelContains("Which caching"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-question-2")

        // Tap first option (single-select auto-advances to review)
        TestStep.iosTap(.labelContains("Redis"))

        // Verify review summary shows
        TestStep.iosWaitForElement(.labelContains("Review Your Answers"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-review-summary")

        // Confirm answers
        TestStep.iosTap(.labelContains("Confirm"))

        // Verify completion feedback
        TestStep.iosWaitForElement(.labelContains("All questions answered"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-answers-submitted")

        // Navigate back to session list
        TestStep.iosTap(.labelContains("Sessions"))
        TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 5)

        // Re-enter session
        TestStep.iosTap(.labelContains("MyProject"))

        // Verify feedback persists (not prompt box, not questions)
        TestStep.iosWaitForElement(.labelContains("All questions answered"), timeout: 10)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting to terminal"), timeout: 10)
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-questions-answered-persists")

        // ──────────────────────────────────────────────────────────
        // Phase 2: PermissionRequest (Bash tool)
        // ──────────────────────────────────────────────────────────

        // Send PermissionRequest hook (replaces previous feedback)
        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("PermissionRequest"),
                "session_id": .string("e2e-test-session-1"),
                "timestamp": .string("2026-02-14T10:02:00.000000Z"),
                "tool_name": .string("Bash"),
                "tool_input": .object([
                    "command": .string("npm install"),
                    "description": .string("Install dependencies"),
                ]),
            ],
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject",
            sessionID: "e2e-test-session-1"
        )

        // Verify permission request UI shows
        TestStep.iosWaitForElement(.labelContains("Run Command"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("Accept"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-permissions-request")

        // Accept the permission
        TestStep.iosTap(.labelContains("Accept"))

        // Verify acceptance feedback
        TestStep.iosWaitForElement(.labelContains("Permission accepted"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-permission-accepted")

        // Navigate back
        TestStep.iosTap(.labelContains("Sessions"))
        TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 5)

        // Re-enter session
        TestStep.iosTap(.labelContains("MyProject"))

        // Verify feedback persists
        TestStep.iosWaitForElement(.labelContains("Permission accepted"), timeout: 10)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting to terminal"), timeout: 10)
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-permission-accepted-persists")

        // ──────────────────────────────────────────────────────────
        // Phase 3: ExitPlanMode (plan approval)
        // ──────────────────────────────────────────────────────────

        // Send ExitPlanMode hook (replaces previous feedback)
        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("PermissionRequest"),
                "session_id": .string("e2e-test-session-1"),
                "timestamp": .string("2026-02-14T10:03:00.000000Z"),
                "tool_name": .string("ExitPlanMode"),
                "tool_input": .object([
                    "plan": .string(
                        "# Implementation Plan\n\n1. Add authentication\n2. Add unit tests"
                    ),
                    "allowedPrompts": .array([
                        .object([
                            "tool": .string("Bash"),
                            "prompt": .string("run tests"),
                        ]),
                    ]),
                ]),
            ],
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject",
            sessionID: "e2e-test-session-1"
        )

        // Verify plan approval UI shows
        TestStep.iosWaitForElement(.labelContains("Plan Approval"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("Approve"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-plan-approval")

        // Approve the plan
        TestStep.iosTap(.labelContains("Approve"))

        // Verify acceptance feedback (ExitPlanMode sets .accepted → "Permission accepted")
        TestStep.iosWaitForElement(.labelContains("Permission accepted"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-plan-approved")

        // Navigate back
        TestStep.iosTap(.labelContains("Sessions"))
        TestStep.iosWaitForElement(.labelContains("MyProject"), timeout: 5)

        // Re-enter session
        TestStep.iosTap(.labelContains("MyProject"))

        // Verify feedback persists
        TestStep.iosWaitForElement(.labelContains("Permission accepted"), timeout: 10)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting to terminal"), timeout: 10)
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "ios-plan-approved-persists")
    }
}
