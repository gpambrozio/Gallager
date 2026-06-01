import Foundation

/// E2E scenario: Codex drives the permission / AskUserQuestion / plan-approval
/// forms (not just reply-after-stop).
///
/// `CodexResponseRoundTripScenario` only exercises the Codex reply form, but
/// `CodexTranslator` maps all five response types and `CodexKeystrokes` delivers
/// each. This drives the other agent-blind forms through the iOS UI and proves
/// the Codex keystrokes actually land in the pane:
/// - Permission → deny-with-feedback: the typed feedback reaches the pane.
/// - AskUserQuestion → answered via "Other": the free-text answer reaches the pane.
/// - ExitPlanMode → Approve: the plan-approval form renders and accepts.
///
/// The forms are agent-blind (same SwiftUI as Claude), so this guards the Codex
/// `deliverResponse` → `CodexKeystrokes` half of each round-trip.
public enum CodexFormsParityScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Codex Forms Parity",
        tags: ["hooks", "codex", "response"]
    ) {
        // Setup: pair + a Codex session on its own pane.
        FreshPairingScenario.scenario
        TestStep.tmuxCreateSession(name: "codex-forms", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "codex-forms:0.0", storeAs: "codexFormsPane")
        TestStep.iosWaitForElement(.labelContains("codex-forms"), timeout: 15)

        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-codex-forms",
                "cwd": "/Users/test/CodexForms",
                "timestamp": "2026-05-31T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${codexFormsPane}"
        )
        TestStep.iosWaitForElement(.labelContains("CodexForms"), timeout: 10)
        TestStep.iosTap(.labelContains("CodexForms"))
        TestStep.iosWaitForElement(.labelContains("Send a message to Codex"), timeout: 10)

        // ── Phase 1: permission → deny-with-feedback ─────────────────
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-codex-forms",
                "cwd": "/Users/test/CodexForms",
                "timestamp": "2026-05-31T10:01:00.000000Z",
                "tool_name": "Bash",
                "tool_input": {
                    "command": "rm -rf build",
                    "description": "Clean the build"
                }
            }
            """,
            tmuxPane: "${codexFormsPane}"
        )
        // Agent-neutral assertions (the Codex permission title is the raw tool
        // name, not a Claude-style friendly verb).
        TestStep.iosWaitForElement(.labelContains("Accept"), timeout: 10)
        TestStep.iosWaitForElement(.identifier("permission-custom-instructions"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-codex-permission")

        TestStep.iosTap(.identifier("permission-custom-instructions"))
        TestStep.iosType(text: "codexdenymarker")
        TestStep.iosTap(.label("Send"))
        TestStep.wait(seconds: 6)
        TestStep.tmuxCapturePaneContent(target: "codex-forms:0", storeAs: "codexDenyOut")
        TestStep.assertStoredContains(key: "codexDenyOut", substring: "codexdenymarker")

        // ── Phase 2: AskUserQuestion → answered via "Other" ──────────
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-codex-forms",
                "cwd": "/Users/test/CodexForms",
                "timestamp": "2026-05-31T10:02:00.000000Z",
                "tool_name": "AskUserQuestion",
                "tool_input": {
                    "questions": [
                        {
                            "question": "Which database should Codex use?",
                            "header": "Database",
                            "options": [
                                {"label": "Postgres", "description": "Relational"},
                                {"label": "Mongo", "description": "Document"}
                            ],
                            "multiSelect": false
                        }
                    ]
                }
            }
            """,
            tmuxPane: "${codexFormsPane}"
        )
        TestStep.iosWaitForElement(.labelContains("Which database should Codex use"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-codex-question")
        TestStep.iosTap(.labelContains("Open Other"))
        TestStep.wait(seconds: 1)
        TestStep.iosType(text: "codexothermarker")
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Save Other"))
        TestStep.iosWaitForElement(.labelContains("Other: codexothermarker"), timeout: 5)
        TestStep.iosTap(.labelContains("Confirm"))
        TestStep.iosWaitForElement(.labelContains("All questions answered"), timeout: 5)
        TestStep.wait(seconds: 8)
        TestStep.tmuxCapturePaneContent(target: "codex-forms:0", storeAs: "codexQuestionOut")
        TestStep.assertStoredContains(key: "codexQuestionOut", substring: "codexothermarker")

        // ── Phase 3: ExitPlanMode → Approve ──────────────────────────
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-codex-forms",
                "cwd": "/Users/test/CodexForms",
                "timestamp": "2026-05-31T10:03:00.000000Z",
                "tool_name": "ExitPlanMode",
                "tool_input": {
                    "plan": "# Codex plan\\n\\n1. Wire the API\\n2. Add tests"
                }
            }
            """,
            tmuxPane: "${codexFormsPane}"
        )
        TestStep.iosWaitForElement(.labelContains("Plan Approval"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("Approve"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-codex-plan")
        TestStep.iosTap(.labelContains("Approve"))
        TestStep.iosWaitForElement(.labelContains("Permission accepted"), timeout: 5)
    }
}
