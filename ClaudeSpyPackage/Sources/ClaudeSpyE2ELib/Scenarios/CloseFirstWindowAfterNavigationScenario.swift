import Foundation

/// E2E scenario: Close the first window after navigating between windows.
///
/// Reproduces the bug where the surviving window's terminal is blank after:
/// 1. Launch with no sessions; click 'New Terminal' in the empty-state UI.
///    This creates a session via `tmuxService.createSession`.
/// 2. Tap '+' on the tab bar to create a second window
/// 3. Click the first window's tab to navigate back to it
/// 4. Tap 'X' on the first window's tab to close it
/// 5. Window 1 (the new window) becomes selected — should render its terminal
///
/// The session-creation path matters: this is what the user reported as the
/// trigger for the post-PR-#394 regression.
public enum CloseFirstWindowAfterNavigationScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Close First Window After Navigation",
        tags: ["tabs", "macos-only"]
    ) {
        // 1. Launch the app on a clean tmux server (no pre-existing sessions);
        //    the empty-state shows a 'New Terminal' button directly.
        TestStep.log("Stage 1: Launch app with no sessions")
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 2)

        // 2. Click 'New Terminal' in the empty-state to create the first
        //    session via tmuxService.createSession.
        TestStep.log("Stage 2: Click 'New Terminal' in empty state")
        TestStep.macClickButton(titled: "New Terminal")
        TestStep.wait(seconds: 5)

        // The first window tab is labeled "terminal 1" (the createSession
        // path names it explicitly). Find any selected tab to confirm.
        TestStep.macWaitForElementQuery(.valueContains("selected"), timeout: 8)
        TestStep.macScreenshot(label: "mac-window-0-after-create")

        // 3. Tab-bar '+' → create window 1, then fill it with distinctive
        //    text. The post-close baseline encodes that text, so a regression
        //    that blanks the surviving terminal produces a screenshot diff
        //    well above tolerance.
        TestStep.log("Stage 3: Tab-bar '+' to create window 1 and fill with text")
        // The "+" is a SwiftUI Menu — AXPress doesn't reliably open the
        // popup, so open it with a CGEvent click and then press the menu
        // item. Same pattern as TabReorderScenario.
        TestStep.macCGClickElement(query: .label("New Tab"))
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "New Terminal")
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElement(titled: "terminal 2", timeout: 5)

        // Use the stable pane id rather than `terminal:N.M` since both
        // base-index and pane-base-index depend on the user's tmux config.
        // The new pane is %1 in this scenario (first session %0, "+" → %1).
        Shortcut.tmuxClearAndSetPrompt(target: "%1")
        Shortcut.tmuxRunCommand(
            target: "%1",
            command: "for i in 1 2 3 4 5 6 7 8 9 10; do echo \"=== WINDOW 2 LINE $i ===\"; done"
        )
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-window-1-just-created")

        // 4. Click the first window tab to navigate back to it
        TestStep.log("Stage 4: Click 'terminal 1' tab")
        TestStep.macClickButton(titled: "terminal 1")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-window-0-reselected")

        // 5. Click 'X' on window 0; window 1 should survive and render
        TestStep.log("Stage 5: Click 'X' on window 0")
        TestStep.macClickButton(titled: "Close window")
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElementToDisappear(titled: "terminal 1", timeout: 5)
        TestStep.macWaitForElement(titled: "terminal 2", timeout: 5)
        // The terminal must render content immediately (shell prompt visible).
        // Regression check for the kill-window-with-renumbering bug where
        // capture-pane used a stale window-relative target.
        TestStep.macScreenshot(label: "mac-window-1-after-closing-window-0")
    }
}
