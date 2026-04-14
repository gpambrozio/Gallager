import Foundation

/// E2E scenario: Verify mouse mode sync, scroll wheel, click, and drag event delivery.
///
/// Uses a Python test app that enables mouse tracking (SGR mode) and renders
/// observable counters for scroll and click events, including click coordinates.
/// The test verifies the full round-trip: CGEvent → SGR escape sequence →
/// tmux send-keys -H → Python app state change → tmux capture-pane.
public enum MouseSupportScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Mouse Support",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Create tmux sessions ─────────────────────────────────
        TestStep.log("Creating tmux session for mouse support test")
        TestStep.tmuxCreateSession(name: "mouse-test", width: 80, height: 24)

        Shortcut.tmuxClearAndSetPrompt(target: "mouse-test:0")

        // ── Inject Python mouse test app ──────────────────────────
        TestStep.log("Injecting mouse test app")
        TestStep.injectScript(name: "mouse_test.py")

        // ── Run the test app ─────────────────────────────────────
        TestStep.log("Starting mouse test app")
        Shortcut.tmuxRunCommand(target: "mouse-test:0", command: "python3 $TMPDIR/mouse_test.py")
        TestStep.wait(seconds: 2)

        // Verify the app started and mouse mode is active
        TestStep.tmuxCapturePaneContent(target: "mouse-test:0", storeAs: "initial-content")
        TestStep.assertStoredContains(key: "initial-content", substring: "STATUS:READY")
        TestStep.assertStoredContains(key: "initial-content", substring: "SCROLL:0")

        TestStep.tmuxStoreDisplayMessage(
            target: "mouse-test:0",
            format: "#{mouse_any_flag}",
            storeAs: "mouseAnyFlag"
        )
        TestStep.assertStoredContains(key: "mouseAnyFlag", substring: "1")
        TestStep.log("Mouse mode confirmed active: mouse_any_flag=${mouseAnyFlag}")

        // ── Launch macOS app and connect ─────────────────────────
        Shortcut.macOnlySetup
        TestStep.macClickButton(titled: "mouse-test")
        TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "mouse-mode-connected")

        // ── Test scroll down ─────────────────────────────────────
        TestStep.log("Sending scroll-down events")
        TestStep.macScrollWheel(deltaY: -1, count: 5)
        TestStep.wait(seconds: 2)

        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("SCROLL:-")]),
            timeout: 10
        )

        // ── Test scroll up ───────────────────────────────────────
        TestStep.log("Sending scroll-up events")
        TestStep.macScrollWheel(deltaY: 1, count: 10)
        TestStep.wait(seconds: 2)

        // Net scroll should now be +5 (10 up - 5 down)
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("SCROLL:5")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "after-scroll")

        // ── Test click ───────────────────────────────────────────
        // Window is at (10, 10) with 250px sidebar, 1000×600 total.
        // Terminal area starts around x=260. Click in the middle of
        // the terminal to verify click events arrive with coordinates.
        TestStep.log("Sending click event")
        TestStep.macClickAtPoint(x: 450, y: 200)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("CLICK:1")]),
            timeout: 10
        )

        // ── Test second click at different position ──────────────
        TestStep.log("Sending second click at different position")
        TestStep.macClickAtPoint(x: 650, y: 350)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("CLICK:2")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "after-clicks")

        // ── Test drag ─────────────────────────────────────────────
        // Drag across the terminal area to verify SGR drag (motion)
        // sequences are synthesized and delivered to the app.
        TestStep.log("Sending drag event")
        TestStep.macDrag(fromX: 400, fromY: 200, toX: 700, toY: 400)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("DRAG:")]),
            timeout: 10
        )
        // Verify drag count is at least 1 (likely many more from intermediate points)
        TestStep.tmuxCapturePaneContent(target: "mouse-test:0", storeAs: "after-drag")
        TestStep.assertStoredNotContains(key: "after-drag", substring: "DRAG:0")
        TestStep.macScreenshot(label: "after-drag")

        // ── Verify drag caused exactly one extra click ───────────
        // A drag starts with mouseDown which the app sees as a click,
        // so the count goes from 2 → 3. No spurious extra clicks beyond that.
        TestStep.assertStoredContains(key: "after-drag", substring: "CLICK:3")
        TestStep.assertStoredNotContains(key: "after-drag", substring: "CLICK:4")

        // ── Stop the test app ────────────────────────────────────
        TestStep.tmuxSendKeys(target: "mouse-test:0", keys: "C-c")
        TestStep.wait(seconds: 1)
    }
}
