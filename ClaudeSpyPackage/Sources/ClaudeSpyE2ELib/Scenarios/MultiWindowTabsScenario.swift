import Foundation

/// E2E scenario: Multi-window tabs in a session
///
/// Verifies that tmux windows within a session are shown as horizontal tabs:
/// 1. Create a session with a single window — sidebar shows session, tab bar visible with one tab + "+"
/// 2. Create a second window via tmux — tab bar shows two tabs
/// 3. Switch between tabs — detail view updates to the selected window
/// 4. Create a third window — three tabs visible
/// 5. Close a window — tab count decreases
public enum MultiWindowTabsScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Multi Window Tabs",
        tags: ["sidebar", "tabs", "macos-only"]
    ) {
        // ── Stage 1: Single-window session ────────────────────────

        TestStep.log("Stage 1: Create session with a single window")
        TestStep.tmuxCreateSession(name: "tabtest", width: 160, height: 50)

        // Produce some output
        Shortcut.tmuxRunCommand(target: "tabtest:0.0", command: "echo '=== WINDOW 0 ==='")
        TestStep.wait(seconds: 1)

        // Launch macOS app and open Panes window
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        // Select the session — sidebar shows "tabtest" (session name, not window ID)
        TestStep.log("Verify sidebar shows 'tabtest' and select it")
        TestStep.macWaitForElement(titled: "tabtest", timeout: 5)
        TestStep.macClickButton(titled: "tabtest")
        TestStep.wait(seconds: 3)

        // Tab bar should show window 0 tab, selected
        TestStep.macScreenshot(label: "mac-single-window-with-tab")
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabtest:0"), .valueContains("selected")]), timeout: 5)

        // ── Stage 2: Create a second window ─────────────────────

        TestStep.log("Stage 2: Create a second window in the session")
        Shortcut.tmuxRunCommand(target: "tabtest:0.0", command: "tmux new-window -t tabtest")
        TestStep.wait(seconds: 3)

        // The new window should appear as a second tab
        Shortcut.tmuxRunCommand(target: "tabtest:1.0", command: "echo '=== WINDOW 1 ==='")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "mac-two-window-tabs")

        // ── Stage 3: Switch to first window tab ──────────────────

        TestStep.log("Stage 3: Click on the first window tab (0)")
        TestStep.macClickButton(titled: "tabtest:0")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "mac-switched-to-window-0")
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabtest:0"), .valueContains("selected")]), timeout: 5)

        // ── Stage 4: Switch back to second window tab ────────────

        TestStep.log("Stage 4: Click on the second window tab (1)")
        TestStep.macClickButton(titled: "tabtest:1")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "mac-switched-to-window-1")
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabtest:1"), .valueContains("selected")]), timeout: 5)

        // ── Stage 4b: Re-selecting session opens tmux-active window ──

        TestStep.log("Stage 4b: Verify sidebar click opens the tmux-active window")

        // Create a temporary session to deselect tabtest
        TestStep.tmuxCreateSession(name: "temp-deselect", width: 160, height: 50)
        // Longer timeout: the sidebar discovery for a newly-created session can
        // take more than 5s in a busy scenario (#540 removed a 2s pre-wait here).
        TestStep.macWaitForElement(titled: "temp-deselect", timeout: 15)
        TestStep.macClickButton(titled: "temp-deselect")
        TestStep.wait(seconds: 2)

        // Switch tmux to window 0 in tabtest (making it the tmux-active window)
        Shortcut.tmuxRunCommand(target: "temp-deselect:0.0", command: "tmux select-window -t tabtest:0")
        TestStep.wait(seconds: 2)

        // Re-click tabtest — should open window 0 (the tmux-active window), not window 1
        TestStep.macClickButton(titled: "tabtest")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "mac-reselect-opens-active-window")
        TestStep.macWaitForElementQuery(.allOf([.labelContains("tabtest:0"), .valueContains("selected")]), timeout: 5)

        // Clean up temp session
        Shortcut.tmuxRunCommand(target: "temp-deselect:0.0", command: "exit")
        TestStep.macWaitForElementToDisappear(titled: "temp-deselect", timeout: 5)

        // ── Stage 5: Create third window ─────────────────────────

        TestStep.log("Stage 5: Create a third window")
        Shortcut.tmuxRunCommand(target: "tabtest:1.0", command: "tmux new-window -t tabtest")
        TestStep.wait(seconds: 3)

        Shortcut.tmuxRunCommand(target: "tabtest:2.0", command: "echo '=== WINDOW 2 ==='")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "mac-three-window-tabs")

        // ── Stage 6: Close middle window (window 1) ──────────────

        TestStep.log("Stage 6: Close window 1 — should leave windows 0 and 2")
        Shortcut.tmuxRunCommand(target: "tabtest:1.0", command: "exit")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "mac-after-close-window-1")

        // ── Stage 7: Close remaining windows ─────────────────────

        TestStep.log("Stage 7: Close all remaining windows — session should disappear")
        Shortcut.tmuxRunCommand(target: "tabtest:2.0", command: "exit")
        TestStep.wait(seconds: 3)

        Shortcut.tmuxRunCommand(target: "tabtest:0.0", command: "exit")

        // The session should vanish from the sidebar
        TestStep.macWaitForElementToDisappear(titled: "tabtest", timeout: 10)
        TestStep.macScreenshot(label: "mac-no-sessions-empty-state")
    }
}
