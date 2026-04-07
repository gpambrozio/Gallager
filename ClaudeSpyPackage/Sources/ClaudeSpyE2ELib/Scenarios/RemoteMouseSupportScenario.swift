import Foundation

/// E2E scenario: Verify mouse events are forwarded from a Mac viewer to the host.
///
/// Uses the same Python test app as `MouseSupportScenario` but runs it on the host
/// (instance 0) and sends scroll/click events from the viewer (instance 1).
/// Verifies the full round-trip: viewer CGEvent → SGR escape → relay → host tmux →
/// Python app state change → tmux capture-pane.
///
/// **Important:** The mouse test app must start *after* the viewer is streaming so
/// that both terminals receive the escape codes that enable mouse mode. If the app
/// starts before the viewer connects, the viewer's SwiftTerm never enters mouse mode
/// and scroll events are handled locally instead of forwarded.
public enum RemoteMouseSupportScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Remote Mouse Support",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup: Pair two Mac apps ─────────────────────────────
        Shortcut.twoMacPairing

        // ── Create tmux session on host ──────────────────────────
        TestStep.log("Creating tmux session for remote mouse test")
        TestStep.tmuxCreateSession(name: "remote-mouse", width: 80, height: 24)

        Shortcut.tmuxClearAndSetPrompt(target: "remote-mouse:0")

        // ── Open panes on host and connect to session ────────────
        TestStep.log("Opening panes on host (instance 0)")
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "remote-mouse", timeout: 10)
        TestStep.macClickButton(titled: "remote-mouse")
        TestStep.wait(seconds: 3)

        // ── Open panes on viewer and connect to session ──────────
        TestStep.log("Opening panes on viewer (instance 1)")
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macWaitForElement(titled: "remote-mouse", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "remote-mouse", instance: 1)
        TestStep.wait(seconds: 3)

        // ── Inject and run the Python mouse test app ─────────────
        // Must start AFTER viewer is streaming so both terminals
        // receive the escape codes that enable mouse mode.
        TestStep.log("Injecting and starting mouse test app")
        TestStep.injectScript(name: "mouse_test.py")
        Shortcut.tmuxRunCommand(target: "remote-mouse:0", command: "python3 $TMPDIR/mouse_test.py")
        TestStep.wait(seconds: 2)

        // Verify app is running and mouse mode active
        TestStep.tmuxCapturePaneContent(target: "remote-mouse:0", storeAs: "initial-content")
        TestStep.assertStoredContains(key: "initial-content", substring: "STATUS:READY")
        TestStep.assertStoredContains(key: "initial-content", substring: "SCROLL:0")

        TestStep.tmuxStoreDisplayMessage(
            target: "remote-mouse:0",
            format: "#{mouse_any_flag}",
            storeAs: "mouseAnyFlag"
        )
        TestStep.assertStoredContains(key: "mouseAnyFlag", substring: "1")

        // Verify both host and viewer see the mouse test app
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("STATUS:READY")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "host-connected")

        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("STATUS:READY")]),
            timeout: 10,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-connected", instance: 1)

        // ── Test scroll down from viewer ─────────────────────────
        TestStep.log("Sending scroll-down events from viewer")
        TestStep.macScrollWheel(deltaY: -1, count: 5, instance: 1)
        TestStep.wait(seconds: 2)

        // Verify scroll events arrived at host tmux via relay
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("SCROLL:-")]),
            timeout: 10
        )

        // ── Test scroll up from viewer ───────────────────────────
        TestStep.log("Sending scroll-up events from viewer")
        TestStep.macScrollWheel(deltaY: 1, count: 10, instance: 1)
        TestStep.wait(seconds: 2)

        // Net scroll should be +5 (10 up - 5 down)
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("SCROLL:5")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "after-scroll-host")
        TestStep.macScreenshot(label: "after-scroll-viewer", instance: 1)

        // ── Test click from viewer ───────────────────────────────
        // Viewer window is at (10, 10) with 250px sidebar, 1000×600 total.
        // Terminal area starts around x=260.
        TestStep.log("Sending click event from viewer")
        TestStep.macClickAtPoint(x: 450, y: 200, instance: 1)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("CLICK:1")]),
            timeout: 10
        )

        // ── Test second click at different position ──────────────
        TestStep.log("Sending second click from viewer")
        TestStep.macClickAtPoint(x: 650, y: 350, instance: 1)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("CLICK:2")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "after-clicks-host")
        TestStep.macScreenshot(label: "after-clicks-viewer", instance: 1)

        // ── Verify no spurious clicks ────────────────────────────
        TestStep.tmuxCapturePaneContent(target: "remote-mouse:0", storeAs: "after-clicks")
        TestStep.assertStoredNotContains(key: "after-clicks", substring: "CLICK:3")

        // ── Cleanup ──────────────────────────────────────────────
        TestStep.tmuxSendKeys(target: "remote-mouse:0", keys: "C-c")
        TestStep.wait(seconds: 1)
    }
}
