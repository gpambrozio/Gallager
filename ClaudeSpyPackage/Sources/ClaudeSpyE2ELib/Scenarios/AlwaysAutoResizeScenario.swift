import Foundation

/// E2E test for the "Always auto-resize terminals" global preference.
///
/// Verifies: global default on, new session inherits, per-session opt-out,
/// global off restores normal behavior. Also checks the toolbar toggle's
/// checked/unchecked state at each stage.
public enum AlwaysAutoResizeScenario {
    /// ElementQuery matching the auto-resize toolbar toggle when checked (value "1")
    private static let autoResizeChecked = ElementQuery.allOf([
        .help("Auto-resize tmux pane when mirror view changes size"),
        .valueContains("1"),
    ])

    /// ElementQuery matching the auto-resize toolbar toggle when unchecked (value "0")
    private static let autoResizeUnchecked = ElementQuery.allOf([
        .help("Auto-resize tmux pane when mirror view changes size"),
        .valueContains("0"),
    ])

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Always Auto-Resize Preference",
        tags: ["resize", "macos-only"]
    ) {
        // ── Setup ──────────────────────────────────────────────────

        TestStep.log("Creating initial tmux session")
        TestStep.tmuxCreateSession(name: "always-resize-1", width: 80, height: 24)

        Shortcut.macOnlySetup

        // Select pane
        TestStep.macClickButton(titled: "always-resize-1")
        TestStep.wait(seconds: 1)

        // ── Phase 1: Global setting enables auto-resize ───────────

        TestStep.log("Phase 1: Enable global auto-resize")

        // Verify toggle is unchecked and manual resize button is present
        TestStep.macWaitForElementQuery(autoResizeUnchecked, timeout: 5)
        TestStep.macWaitForElement(titled: "Resize tmux pane to fit mirror view", timeout: 2)

        // Record initial dimensions
        TestStep.tmuxStorePaneDimensions(
            target: "always-resize-1:0",
            widthKey: "initialWidth",
            heightKey: "initialHeight"
        )
        TestStep.log("Initial dimensions: ${initialWidth}x${initialHeight}")

        // Open Settings, enable the global toggle, then close Settings
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macClickButton(titled: "Automatically resize all terminal panes to fit the mirror view when the window size changes")
        TestStep.wait(seconds: 1)
        TestStep.macCloseWindow(titled: "General")
        TestStep.wait(seconds: 1)

        // Re-select the pane (toolbar needs the pane focused after settings closes)
        TestStep.macClickButton(titled: "always-resize-1")
        TestStep.wait(seconds: 1)

        // Verify toggle is now checked and manual resize button is hidden
        TestStep.macWaitForElementQuery(autoResizeChecked, timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "Resize tmux pane to fit mirror view", timeout: 5)

        // Resize window larger to trigger auto-resize
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        // Verify dimensions changed
        TestStep.tmuxStorePaneDimensions(
            target: "always-resize-1:0",
            widthKey: "phase1Width",
            heightKey: "phase1Height"
        )
        TestStep.log("Phase 1 dimensions: ${phase1Width}x${phase1Height}")
        TestStep.assertStoredNotEqual(key: "phase1Width", otherKey: "initialWidth")
        TestStep.macScreenshot(label: "mac-global-auto-resize-on")

        // ── Phase 2: New session inherits global default ──────────

        TestStep.log("Phase 2: New session inherits global auto-resize")

        // Create a new tmux session
        TestStep.tmuxCreateSession(name: "always-resize-2", width: 80, height: 24)
        TestStep.wait(seconds: 2)

        // Select the new pane
        TestStep.macClickButton(titled: "always-resize-2")
        TestStep.wait(seconds: 1)

        // Verify toggle is checked (inherited from global) and manual resize hidden
        TestStep.macWaitForElementQuery(autoResizeChecked, timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "Resize tmux pane to fit mirror view", timeout: 5)

        // Resize window — new pane should auto-resize too
        TestStep.macResizeWindow(width: 1_000, height: 700)
        TestStep.wait(seconds: 1)

        TestStep.tmuxStorePaneDimensions(
            target: "always-resize-2:0",
            widthKey: "phase2Width",
            heightKey: "phase2Height"
        )
        TestStep.log("Phase 2 dimensions: ${phase2Width}x${phase2Height}")

        // Should not be the original 80 anymore
        TestStep.storeValue(key: "original80", value: "80")
        TestStep.assertStoredNotEqual(key: "phase2Width", otherKey: "original80")
        TestStep.macScreenshot(label: "mac-new-session-inherits")

        // ── Phase 3: Per-session opt-out ──────────────────────────

        TestStep.log("Phase 3: Per-session opt-out while global is on")

        // Disable auto-resize for pane 2 by clicking the toggle
        TestStep.macClickButton(titled: "Auto-resize tmux pane when mirror view changes size")
        TestStep.wait(seconds: 0.5)

        // Verify toggle is now unchecked and manual resize reappears
        TestStep.macWaitForElementQuery(autoResizeUnchecked, timeout: 5)
        TestStep.macWaitForElement(titled: "Resize tmux pane to fit mirror view", timeout: 5)

        // Record pane 2 dimensions before resize
        TestStep.tmuxStorePaneDimensions(
            target: "always-resize-2:0",
            widthKey: "phase3BeforeWidth",
            heightKey: "phase3BeforeHeight"
        )

        // Resize window
        TestStep.macResizeWindow(width: 900, height: 600)
        TestStep.wait(seconds: 1)

        // Pane 2 should NOT have resized (opted out)
        TestStep.tmuxStorePaneDimensions(
            target: "always-resize-2:0",
            widthKey: "phase3AfterWidth",
            heightKey: "phase3AfterHeight"
        )
        TestStep.log("Phase 3 pane 2: ${phase3BeforeWidth}→${phase3AfterWidth}")
        TestStep.assertStoredEqual(key: "phase3AfterWidth", otherKey: "phase3BeforeWidth")

        // Switch to pane 1 — it should still auto-resize (global default, no opt-out)
        TestStep.macClickButton(titled: "always-resize-1")
        TestStep.wait(seconds: 1)

        // Verify toggle is checked for pane 1
        TestStep.macWaitForElementQuery(autoResizeChecked, timeout: 5)

        TestStep.tmuxStorePaneDimensions(
            target: "always-resize-1:0",
            widthKey: "phase3Pane1Width",
            heightKey: "phase3Pane1Height"
        )
        TestStep.log("Phase 3 pane 1: ${phase3Pane1Width}x${phase3Pane1Height}")
        // Pane 1 should have resized to the new window size (different from phase 1)
        TestStep.assertStoredNotEqual(key: "phase3Pane1Width", otherKey: "phase1Width")
        TestStep.macScreenshot(label: "mac-per-session-opt-out")

        // ── Phase 4: Global off restores normal behavior ──────────

        TestStep.log("Phase 4: Disable global auto-resize")

        // Open Settings, disable the global toggle, then close Settings
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macClickButton(titled: "Automatically resize all terminal panes to fit the mirror view when the window size changes")
        TestStep.wait(seconds: 1)
        TestStep.macCloseWindow(titled: "General")
        TestStep.wait(seconds: 1)

        // Re-select pane (toolbar needs the pane focused)
        TestStep.macClickButton(titled: "always-resize-1")
        TestStep.wait(seconds: 1)

        // Verify toggle is unchecked for pane 1 (global off, opt-outs cleared)
        TestStep.macWaitForElementQuery(autoResizeUnchecked, timeout: 5)
        TestStep.macWaitForElement(titled: "Resize tmux pane to fit mirror view", timeout: 5)

        // Record pane 1 dimensions before resize
        TestStep.tmuxStorePaneDimensions(
            target: "always-resize-1:0",
            widthKey: "phase4BeforeWidth",
            heightKey: "phase4BeforeHeight"
        )

        // Resize window
        TestStep.macResizeWindow(width: 900, height: 600)
        TestStep.wait(seconds: 1)

        // Pane 1 should NOT have resized (global off, no per-session toggle)
        TestStep.tmuxStorePaneDimensions(
            target: "always-resize-1:0",
            widthKey: "phase4AfterWidth",
            heightKey: "phase4AfterHeight"
        )
        TestStep.log("Phase 4 pane 1: ${phase4BeforeWidth}→${phase4AfterWidth}")
        TestStep.assertStoredEqual(key: "phase4AfterWidth", otherKey: "phase4BeforeWidth")
        TestStep.macScreenshot(label: "mac-global-off-no-resize")
    }
}
