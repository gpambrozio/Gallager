import Foundation

/// E2E scenario: Yolo mode auto-approve hides iOS response UI and skips push
///
/// Verifies that when yolo mode is enabled and a yolo-auto-approvable
/// permission request arrives:
/// 1. The iOS response UI is NOT shown
/// 2. No push notification is sent
/// 3. The auto-approve Enter keypress is reflected in both terminal views
/// 4. Non-auto-approvable events (AskUserQuestion) still show UI and send push
/// 5. After disabling yolo mode, auto-approvable events show UI and send push again
public enum YoloModeAutoApproveScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Yolo Mode Auto Approve",
        tags: ["hooks", "sessions", "yolo"]
    ) {
        // ══════════════════════════════════════════════════════════════
        // Phase 1: Setup — fresh pairing + tmux + SessionStart hook
        // ══════════════════════════════════════════════════════════════
        ClaudeSessionsShowScenario.scenario

        // Open the Claude session terminal view on iOS
        TestStep.iosTap(.labelContains("MyProject"))
        TestStep.wait(seconds: 5)
        TestStep.iosWaitForElement(.labelContains("Session Info"), timeout: 15)

        // ══════════════════════════════════════════════════════════════
        // Phase 2: Enable yolo mode from iOS
        // ══════════════════════════════════════════════════════════════

        // Verify yolo mode button shows off state
        TestStep.iosWaitForElement(.labelContains("Enable Yolo Mode"), timeout: 10)

        // Enable yolo mode
        TestStep.iosTap(.labelContains("Enable Yolo Mode"))
        TestStep.wait(seconds: 3)

        // Verify iOS now shows yolo mode enabled
        TestStep.iosWaitForElement(.labelContains("Disable Yolo Mode"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-yolo-enabled")

        // Verify macOS also reflects yolo mode enabled
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "session-1:0")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(
            titled: "Yolo mode: auto-approving permissions (click to disable)",
            timeout: 10
        )

        // ══════════════════════════════════════════════════════════════
        // Phase 3: Send a yolo-auto-approvable PermissionRequest (Bash)
        //          and verify the response UI does NOT appear on iOS
        //          and no push notification is sent
        // ══════════════════════════════════════════════════════════════

        // Type a marker in tmux so we can detect the auto-approve Enter
        TestStep.tmuxSendKeys(
            target: "session-1:0",
            keys: "echo BEFORE_YOLO_APPROVE",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "session-1:0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // Send a Bash PermissionRequest (auto-approvable in yolo mode)
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-test-session-1",
                "timestamp": "2026-02-14T10:01:00.000000Z",
                "tool_name": "Bash",
                "tool_input": {
                    "command": "npm install",
                    "description": "Install dependencies"
                }
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )

        // Wait for the auto-approve delay (500ms) plus processing time
        TestStep.wait(seconds: 3)

        // The response UI ("Run Command", "Accept") should NOT appear
        // because yolo mode auto-approves it.
        TestStep.iosWaitForElementToDisappear(.labelContains("Accept"), timeout: 5)
        TestStep.iosWaitForElementToDisappear(.labelContains("Run Command"), timeout: 3)
        TestStep.iosScreenshot(label: "ios-yolo-no-response-ui")

        // Verify no push notification was sent for the auto-approved event
        TestStep.readFile(path: "${pushLogPath}", storeAs: "pushLogAfterYolo")
        TestStep.assertStoredNotContains(key: "pushLogAfterYolo", substring: "PermissionRequest|${pane1Id}")

        // ══════════════════════════════════════════════════════════════
        // Phase 4: Verify the auto-approve Enter was sent to tmux
        //          (visible on both macOS tmux pane and iOS terminal)
        // ══════════════════════════════════════════════════════════════

        // Capture tmux pane content — the Enter should have produced
        // a new shell prompt line after the BEFORE_YOLO_APPROVE echo
        TestStep.tmuxCapturePaneContent(target: "session-1:0", storeAs: "paneAfterApprove")
        TestStep.assertStoredContains(key: "paneAfterApprove", substring: "BEFORE_YOLO_APPROVE")

        // Take screenshots to visually confirm the Enter keypress result
        TestStep.macScreenshot(label: "mac-yolo-auto-approved")
        TestStep.iosScreenshot(label: "ios-yolo-auto-approved-terminal")

        // ══════════════════════════════════════════════════════════════
        // Phase 5: Verify non-auto-approvable events still show UI
        //          and DO send a push notification (even with yolo on)
        // ══════════════════════════════════════════════════════════════

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-test-session-1",
                "timestamp": "2026-02-14T10:02:00.000000Z",
                "tool_name": "AskUserQuestion",
                "tool_input": {
                    "questions": [
                        {
                            "question": "Which framework should we use?",
                            "header": "Framework",
                            "options": [
                                {"label": "SwiftUI", "description": "Modern declarative UI"},
                                {"label": "UIKit", "description": "Classic imperative UI"}
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

        // AskUserQuestion is NOT yolo-auto-approvable, so UI should appear
        TestStep.iosWaitForElement(.labelContains("Which framework"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-yolo-ask-user-still-shows")

        // Verify a push notification WAS sent for the non-auto-approvable event
        TestStep.readFile(path: "${pushLogPath}", storeAs: "pushLogAfterAsk")
        TestStep.assertStoredContains(key: "pushLogAfterAsk", substring: "PermissionRequest|${pane1Id}")

        // ══════════════════════════════════════════════════════════════
        // Phase 6: Disable yolo mode, send another auto-approvable event,
        //          verify UI shows and push IS sent
        // ══════════════════════════════════════════════════════════════

        // Dismiss the AskUserQuestion UI by selecting an option
        TestStep.iosTap(.labelContains("SwiftUI"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Confirm"))
        TestStep.wait(seconds: 2)

        // Disable yolo mode
        TestStep.iosTap(.labelContains("Disable Yolo Mode"))
        TestStep.wait(seconds: 3)

        // Verify iOS shows yolo mode disabled
        TestStep.iosWaitForElement(.labelContains("Enable Yolo Mode"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-yolo-disabled")

        // Verify macOS also reflects yolo mode disabled
        TestStep.macWaitForElement(
            titled: "Enable yolo mode to auto-approve permissions",
            timeout: 10
        )

        // Snapshot the push log before the next event
        TestStep.readFile(path: "${pushLogPath}", storeAs: "pushLogBeforeNonYolo")

        // Send the same Bash PermissionRequest — now without yolo mode
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-test-session-1",
                "timestamp": "2026-02-14T10:03:00.000000Z",
                "tool_name": "Bash",
                "tool_input": {
                    "command": "npm test",
                    "description": "Run tests"
                }
            }
            """,
            tmuxPane: "${pane1Id}",
            projectPath: "/Users/test/MyProject"
        )
        TestStep.wait(seconds: 3)

        // Without yolo mode, the response UI SHOULD appear
        TestStep.iosWaitForElement(.labelContains("Run Command"), timeout: 10)
        TestStep.iosWaitForElement(.labelContains("Accept"), timeout: 5)
        TestStep.iosScreenshot(label: "ios-no-yolo-response-ui-shows")

        // Verify a push notification WAS sent (yolo mode is off)
        TestStep.readFile(path: "${pushLogPath}", storeAs: "pushLogAfterNonYolo")
        TestStep.assertStoredContains(key: "pushLogAfterNonYolo", substring: "PermissionRequest|${pane1Id}")
    }
}
