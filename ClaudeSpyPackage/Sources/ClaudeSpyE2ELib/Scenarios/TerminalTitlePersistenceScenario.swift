import Foundation

/// E2E scenario: Verify terminal titles persist across sidebar selection changes
/// and are detected on inactive panes.
///
/// 1. Create two tmux sessions, select pane 1, set a custom title
/// 2. Switch to pane 2 and back to pane 1 — verify the title is maintained
/// 3. Set a title on pane 2 while pane 1 is selected (inactive pane title change)
/// 4. Switch to pane 2 — verify the title set while inactive is displayed
public enum TerminalTitlePersistenceScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal Title Persistence",
        tags: ["terminal-title", "macos-only"]
    ) {
        // ── Setup ──────────────────────────────────────────────────

        TestStep.log("Creating 2 tmux sessions")
        TestStep.tmuxCreateSession(name: "title-persist-1", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "title-persist-2", width: 80, height: 24)

        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_000, height: 600)
        TestStep.macSetSidebarWidth(250)
        TestStep.wait(seconds: 1)

        // ── Phase 1: Set title on selected pane ──────────────────

        TestStep.log("Phase 1: Select pane 1 and set a custom title")
        TestStep.macWaitForElement(titled: "title-persist-1:0", timeout: 10)
        TestStep.macClickButton(titled: "title-persist-1:0")
        TestStep.wait(seconds: 2)

        TestStep.tmuxSendKeys(
            target: "title-persist-1:0",
            keys: "printf '\\033]2;Persist Title One\\007'",
            literal: false
        )
        TestStep.tmuxSendKeys(target: "title-persist-1:0", keys: "Enter", literal: false)
        TestStep.wait(seconds: 3)

        TestStep.macWaitForElement(titled: "Persist Title One", timeout: 10)
        TestStep.macScreenshot(label: "pane1-title-set")

        // ── Phase 2: Switch away and back — title must persist ───

        TestStep.log("Phase 2: Switch to pane 2 then back to pane 1")
        TestStep.macClickButton(titled: "title-persist-2:0")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "pane2-selected")

        TestStep.macClickButton(titled: "title-persist-1:0")
        TestStep.wait(seconds: 3)

        // Title should still be visible in sidebar and detail view
        TestStep.macWaitForElement(titled: "Persist Title One", timeout: 10)
        TestStep.macScreenshot(label: "pane1-title-persisted")

        // ── Phase 3: Set title on inactive pane ──────────────────

        TestStep.log("Phase 3: Set title on pane 2 while pane 1 is selected")
        TestStep.tmuxSendKeys(
            target: "title-persist-2:0",
            keys: "printf '\\033]2;Inactive Pane Title\\007'",
            literal: false
        )
        TestStep.tmuxSendKeys(target: "title-persist-2:0", keys: "Enter", literal: false)
        TestStep.wait(seconds: 3)

        // Title should appear in sidebar even though pane 2 is not selected
        TestStep.macWaitForElement(titled: "Inactive Pane Title", timeout: 10)
        TestStep.macScreenshot(label: "pane2-title-in-sidebar")

        // ── Phase 4: Select inactive pane — title must show ──────

        TestStep.log("Phase 4: Select pane 2 and verify its title")
        TestStep.macClickButton(titled: "title-persist-2:0")
        TestStep.wait(seconds: 3)

        TestStep.macWaitForElement(titled: "Inactive Pane Title", timeout: 10)
        TestStep.macScreenshot(label: "pane2-title-displayed")
    }
}
