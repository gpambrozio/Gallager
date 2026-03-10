import Foundation

/// E2E test for manual resize, auto-resize, per-session independence,
/// and auto-resize on pane switch (macOS-only, no server/iOS/pairing).
public enum ResizePaneScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Resize Pane",
        tags: ["resize", "macos-only"]
    ) {
        // ── Setup ──────────────────────────────────────────────────

        TestStep.log("Creating tmux sessions on test socket")
        TestStep.tmuxCreateSession(name: "resize-test-1", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "resize-test-2", width: 80, height: 24)

        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_000, height: 600)
        TestStep.macSetSidebarWidth(200)
        TestStep.wait(seconds: 1)

        // Select first pane by clicking the sidebar row
        TestStep.macClickButton(titled: "resize-test-1:0")
        TestStep.wait(seconds: 1)

        // ── Phase 1: Manual Resize ─────────────────────────────────

        TestStep.log("Phase 1: Manual Resize")

        // Type into the app to test keyboard input path (app → SwiftTerm → tmux)
        TestStep.macType(text: "printf '|%9d' $(seq 10 10 190) | tr ' ' -", pressReturn: true)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "80x24", timeout: 1)
        TestStep.macScreenshot(label: "resize-initial-state")

        // Record initial pane dimensions (should be ~80x24)
        TestStep.tmuxStorePaneDimensions(
            target: "resize-test-1:0",
            widthKey: "initialWidth",
            heightKey: "initialHeight"
        )
        TestStep.log("Initial dimensions: ${initialWidth}x${initialHeight}")

        // Resize window to large
        TestStep.macResizeWindow(width: 1_400, height: 900)
        TestStep.wait(seconds: 0.5)

        // Click manual resize button
        TestStep.macClickButton(titled: "Resize tmux pane to fit mirror view")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "resize-after-manual")
        TestStep.macWaitForElement(titled: "157x53", timeout: 1)

        // Record dimensions after manual resize
        TestStep.tmuxStorePaneDimensions(
            target: "resize-test-1:0",
            widthKey: "phase1Width",
            heightKey: "phase1Height"
        )
        TestStep.log("Phase 1 dimensions: ${phase1Width}x${phase1Height}")

        // Assert: pane width changed from initial
        TestStep.assertStoredNotEqual(key: "phase1Width", otherKey: "initialWidth")
        TestStep.macScreenshot(label: "resize-manual-resize")

        // ── Phase 2: Auto-Resize ───────────────────────────────────

        TestStep.log("Phase 2: Auto-Resize")

        // Enable auto-resize toggle
        TestStep.macClickButton(titled: "Auto-resize tmux pane when mirror view changes size")
        TestStep.wait(seconds: 0.5)

        // Resize window smaller
        TestStep.macResizeWindow(width: 900, height: 600)
        // Wait for 200ms debounce + margin
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "resize-window-smaller")
        TestStep.macWaitForElement(titled: "90x33", timeout: 1)

        // Record dimensions after auto-resize
        TestStep.tmuxStorePaneDimensions(
            target: "resize-test-1:0",
            widthKey: "phase2Width",
            heightKey: "phase2Height"
        )
        TestStep.log("Phase 2 dimensions: ${phase2Width}x${phase2Height}")

        // Assert: pane width changed from Phase 1
        TestStep.assertStoredNotEqual(key: "phase2Width", otherKey: "phase1Width")
        TestStep.macScreenshot(label: "resize-auto-resize")

        // ── Phase 3: Per-Session Independence ──────────────────────

        TestStep.log("Phase 3: Per-Session Independence")

        // Select second pane
        TestStep.macClickButton(titled: "resize-test-2:0")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "80x24", timeout: 1)
        TestStep.macType(text: "printf '|%9d' $(seq 10 10 190) | tr ' ' -", pressReturn: true)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "resize-second-pane")

        // Record pane 2 dimensions (should still be 80x53)
        TestStep.tmuxStorePaneDimensions(
            target: "resize-test-2:0",
            widthKey: "pane2BeforeWidth",
            heightKey: "pane2BeforeHeight"
        )
        TestStep.log("Pane 2 before resize: ${pane2BeforeWidth}x${pane2BeforeHeight}")

        // Resize window
        TestStep.macResizeWindow(width: 1_200, height: 800)
        // Wait for debounce
        TestStep.wait(seconds: 1)

        // Record pane 2 dimensions again
        TestStep.tmuxStorePaneDimensions(
            target: "resize-test-2:0",
            widthKey: "pane2AfterWidth",
            heightKey: "pane2AfterHeight"
        )
        TestStep.log("Pane 2 after resize: ${pane2AfterWidth}x${pane2AfterHeight}")
        TestStep.macWaitForElement(titled: "80x24", timeout: 1)

        // Assert: pane 2 width did NOT change (no auto-resize on this pane)
        TestStep.assertStoredEqual(key: "pane2AfterWidth", otherKey: "pane2BeforeWidth")
        TestStep.macScreenshot(label: "resize-per-session-independence")

        // ── Phase 4: Auto-Resize on Pane Switch ────────────────────

        TestStep.log("Phase 4: Auto-Resize on Pane Switch")

        // Select first pane again (should trigger auto-resize from our fix)
        TestStep.macClickButton(titled: "resize-test-1:0")
        // Wait for debounce
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "130x47", timeout: 1)
        TestStep.macType(text: "printf '|%9d' $(seq 10 10 190) | tr ' ' -", pressReturn: true)

        // Record pane 1 dimensions
        TestStep.tmuxStorePaneDimensions(
            target: "resize-test-1:0",
            widthKey: "phase4Width",
            heightKey: "phase4Height"
        )
        TestStep.log("Phase 4 dimensions: ${phase4Width}x${phase4Height}")

        // Assert: pane 1 width changed from Phase 2 (auto-resized to current window size)
        TestStep.assertStoredNotEqual(key: "phase4Width", otherKey: "phase2Width")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "resize-pane-switch-auto-resize")
    }
}
