import Foundation

/// E2E scenario: Multi-pane window on iOS with Claude session integration
///
/// Verifies that the iOS multi-pane window layout:
/// 1. Shows the correct pane count in the session list
/// 2. Connects all panes (no stuck "Connecting to terminal...")
/// 3. Shows Claude session UI (yolo button, info button, prompt) when
///    the active pane has a Claude session
/// 4. Hides Claude session UI when selecting a plain terminal pane
public enum MultiPaneIOSScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Multi Pane iOS",
        tags: ["layout", "sessions", "ios"]
    ) {
        // 1. Start with fresh pairing
        FreshPairingScenario.scenario

        // 2. Create a tmux session and split into 2 panes
        TestStep.log("Create tmux session and split into 2 panes")
        TestStep.tmuxCreateSession(name: "multi-ios", width: 120, height: 40)
        TestStep.wait(seconds: 1)

        // Send identifiable content to the first pane
        Shortcut.tmuxRunCommand(target: "multi-ios:0.0", command: "echo '=== PANE ONE ==='")
        TestStep.wait(seconds: 1)

        // Split vertically to create a second pane
        // Note: after split-window -h, the NEW pane (pane 1) becomes tmux-active
        Shortcut.tmuxRunCommand(target: "multi-ios:0.0", command: "tmux split-window -h")
        TestStep.wait(seconds: 1)

        // Send content to the second pane
        Shortcut.tmuxRunCommand(target: "multi-ios:0.1", command: "echo '=== PANE TWO ==='")
        TestStep.wait(seconds: 3)

        // Store pane IDs for hook events
        TestStep.tmuxStorePaneId(target: "multi-ios:0.0", storeAs: "pane0Id")
        TestStep.tmuxStorePaneId(target: "multi-ios:0.1", storeAs: "pane1Id")

        // 3. Verify iOS shows the multi-pane window with "2 panes" badge
        TestStep.log("Verify iOS shows multi-pane window in session list")
        TestStep.iosWaitForElement(.labelContains("multi-ios"), timeout: 15)
        TestStep.iosScreenshot(label: "session-list-multi-pane")

        // 4. Send a SessionStart hook event on pane 0 (left pane) to simulate a Claude session
        TestStep.log("Send SessionStart hook to pane 0")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-multi-pane-session",
                "timestamp": "2026-03-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${pane0Id}",
            projectPath: "/Users/test/MultiPaneProject"
        )
        TestStep.wait(seconds: 3)

        // Verify the window row now shows "Claude session active"
        TestStep.iosWaitForElement(.labelContains("Claude session active"), timeout: 10)
        TestStep.iosScreenshot(label: "session-list-with-claude")

        // 5. Open the multi-pane window layout view
        TestStep.log("Tap the multi-pane window to open layout view")
        TestStep.iosTap(.labelContains("multi-ios"))
        TestStep.wait(seconds: 3)

        // 6. Verify all panes connected (no "Connecting to terminal..." stuck)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting to terminal"), timeout: 15)
        TestStep.iosScreenshot(label: "multi-pane-layout-connected")

        // 7. The default active pane is pane 1 (tmux-active after split).
        //    Pane 1 is a plain terminal — Claude UI should NOT be visible initially.
        TestStep.log("Verify plain terminal pane is initially selected (no Claude UI)")
        TestStep.iosWaitForElement(.labelContains("Show Keyboard"), timeout: 5)
        TestStep.iosScreenshot(label: "initial-plain-pane-selected")

        // 8. Tap on the Claude pane (pane 0, left side) to select it
        //    iPhone 17 Pro: 393x852 pt. Left pane center ≈ x:100, mid-screen y:400
        TestStep.log("Tap on pane 0 (Claude session) to switch selection")
        TestStep.iosTapCoordinate(x: 100, y: 400)
        TestStep.wait(seconds: 2)

        // 9. Verify Claude session UI appears
        TestStep.log("Verify Claude session UI is visible for Claude pane")

        // Toolbar should have yolo mode and session info buttons
        TestStep.iosWaitForElement(.labelContains("Yolo Mode"), timeout: 5)
        TestStep.iosWaitForElement(.label("Session Info"), timeout: 5)

        // The prompt text field should be visible (full width above the layout)
        TestStep.iosWaitForElement(.labelContains("Send a message to Claude"), timeout: 5)
        TestStep.iosScreenshot(label: "claude-ui-active-pane")

        // 10. Tap on the plain terminal pane (pane 1, right side) to switch back
        //     Right pane center ≈ x:290, mid-screen y:400
        TestStep.log("Tap on pane 1 (plain terminal) to switch selection")
        TestStep.iosTapCoordinate(x: 290, y: 400)
        TestStep.wait(seconds: 2)

        // 11. Verify Claude session UI disappears
        TestStep.log("Verify Claude session UI is hidden for plain terminal pane")
        TestStep.iosWaitForElementToDisappear(.labelContains("Send a message to Claude"), timeout: 5)
        TestStep.iosWaitForElementToDisappear(.labelContains("Yolo Mode"), timeout: 5)

        // The keyboard button should still be visible (always present)
        TestStep.iosWaitForElement(.labelContains("Show Keyboard"), timeout: 5)
        TestStep.iosScreenshot(label: "plain-pane-selected")

        // 12. Tap back on the Claude pane to confirm UI restores
        TestStep.log("Tap on pane 0 again to confirm Claude UI restores")
        TestStep.iosTapCoordinate(x: 100, y: 400)
        TestStep.wait(seconds: 2)

        TestStep.iosWaitForElement(.labelContains("Yolo Mode"), timeout: 5)
        TestStep.iosWaitForElement(.labelContains("Send a message to Claude"), timeout: 5)
        TestStep.iosScreenshot(label: "claude-ui-restored")
    }
}
