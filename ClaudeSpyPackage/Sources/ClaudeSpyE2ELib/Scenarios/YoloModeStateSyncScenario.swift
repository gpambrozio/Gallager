import Foundation

/// E2E scenario: Yolo mode state synchronization
///
/// Verifies that yolo mode state syncs correctly between macOS and iOS:
/// 1. iOS toggles yolo mode on -> host processes it -> iOS sees it reflected back
/// 2. macOS toggles yolo mode off -> iOS sees it reflected
/// 3. macOS toggles yolo mode back on -> iOS sees it reflected
/// 4. iOS toggles yolo mode off -> both iOS and macOS see it disabled
public enum YoloModeStateSyncScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Yolo Mode State Sync",
        tags: ["hooks", "sessions", "yolo"]
    ) {
        // 1. Start with Claude sessions setup (fresh pairing + tmux + SessionStart hook)
        ClaudeSessionsShowScenario.scenario

        // 2. Tap the Claude session on iOS to open the terminal view
        TestStep.iosTap(.labelContains("MyProject"))
        TestStep.wait(seconds: 5)

        // 3-4. Open Commands menu and tap yolo mode to enable it
        Shortcut.iosTapCommandsMenuItem("Enable Yolo Mode", timeout: 10)
        TestStep.wait(seconds: 3)

        // 5. Verify iOS now shows on state (reflected back from host)
        Shortcut.iosVerifyCommandsMenuItem("Disable Yolo Mode", timeout: 10)
        TestStep.iosScreenshot(label: "ios-yolo-enabled")

        // 6. Open the macOS Panes window and select the session pane
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Available Windows", timeout: 5)
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "session-1")
        TestStep.wait(seconds: 1)

        // 7. Verify macOS shows yolo mode as enabled (help text)
        TestStep.macWaitForElement(
            titled: "Yolo mode: auto-approving permissions (click to disable)",
            timeout: 10
        )

        // 8. Toggle yolo mode off from macOS
        TestStep.macClickButton(titled: "Yolo mode: auto-approving permissions (click to disable)")
        TestStep.wait(seconds: 3)

        // 9. Verify iOS sees yolo mode disabled
        Shortcut.iosVerifyCommandsMenuItem("Enable Yolo Mode", timeout: 10)
        TestStep.iosScreenshot(label: "ios-yolo-disabled-from-mac")

        // 10. Verify macOS help text also shows disabled state
        TestStep.macWaitForElement(
            titled: "Enable yolo mode to auto-approve permissions",
            timeout: 5
        )

        // 11. Toggle yolo mode back on from macOS
        TestStep.macClickButton(titled: "Enable yolo mode to auto-approve permissions")
        TestStep.wait(seconds: 3)

        // 12. Verify iOS sees yolo mode enabled again
        Shortcut.iosVerifyCommandsMenuItem("Disable Yolo Mode", timeout: 10)
        TestStep.iosScreenshot(label: "ios-yolo-re-enabled-from-mac")

        // 13. Open Commands menu and tap yolo mode to disable it
        Shortcut.iosTapCommandsMenuItem("Disable Yolo Mode")
        TestStep.wait(seconds: 3)

        // 14. Verify iOS sees yolo mode disabled
        Shortcut.iosVerifyCommandsMenuItem("Enable Yolo Mode", timeout: 10)
        TestStep.iosScreenshot(label: "ios-yolo-disabled-from-ios")

        // 15. Verify macOS also shows yolo mode disabled
        TestStep.macWaitForElement(
            titled: "Enable yolo mode to auto-approve permissions",
            timeout: 10
        )
    }
}
