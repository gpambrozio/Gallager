import Foundation

// swiftlint:disable function_body_length

/// E2E scenario: Verify mouse mode sync, scroll wheel, and click event delivery.
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
        TestStep.log("Creating tmux sessions for mouse support test")
        TestStep.tmuxCreateSession(name: "mouse-test", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "mouse-helper", width: 80, height: 24)

        Shortcut.tmuxClearAndSetPrompt(target: "mouse-helper:0")
        Shortcut.tmuxClearAndSetPrompt(target: "mouse-test:0")

        // ── Write Python mouse test app ──────────────────────────
        TestStep.log("Writing mouse test app")
        TestStep.tmuxSendKeys(
            target: "mouse-helper:0",
            keys: #"""
            cat > /tmp/mouse_test.py << 'PYEOF'
            import sys, os, re, tty, termios, select

            old_settings = termios.tcgetattr(sys.stdin)
            tty.setraw(sys.stdin)

            try:
                # Enable any-event tracking + SGR encoding
                os.write(1, b'\033[?1003h\033[?1006h\033[2J\033[H')

                scroll = 0
                click = 0
                click_col = 0
                click_row = 0

                def render():
                    lines = [
                        'MOUSE-TEST-APP',
                        'SCROLL:%d' % scroll,
                        'CLICK:%d' % click,
                        'CLICK-COL:%d' % click_col,
                        'CLICK-ROW:%d' % click_row,
                        'STATUS:READY',
                    ]
                    os.write(1, b'\033[H')
                    for line in lines:
                        os.write(1, (line + '\033[K\r\n').encode())

                render()

                buf = b''
                while True:
                    r, _, _ = select.select([sys.stdin], [], [], 0.1)
                    if not r:
                        continue
                    data = os.read(sys.stdin.fileno(), 4096)
                    if not data:
                        break
                    buf += data
                    changed = False
                    while True:
                        m = re.search(rb'\x1b\[<(\d+);(\d+);(\d+)([Mm])', buf)
                        if not m:
                            esc = buf.find(b'\x1b')
                            if esc > 0:
                                buf = buf[esc:]
                            elif esc == -1:
                                buf = b''
                            break
                        btn = int(m.group(1))
                        col = int(m.group(2))
                        row = int(m.group(3))
                        press = m.group(4) == b'M'
                        buf = buf[m.end():]
                        if btn == 64:
                            scroll += 1
                            changed = True
                        elif btn == 65:
                            scroll -= 1
                            changed = True
                        elif btn == 0 and press:
                            click += 1
                            click_col = col
                            click_row = row
                            changed = True
                    if changed:
                        render()
            finally:
                termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
                os.write(1, b'\033[?1003l\033[?1006l')
            PYEOF
            """#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "mouse-helper:0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // ── Run the test app ─────────────────────────────────────
        TestStep.log("Starting mouse test app")
        Shortcut.tmuxRunCommand(target: "mouse-test:0", command: "python3 /tmp/mouse_test.py")
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
        TestStep.macScrollWheel(deltaY: -3, count: 5)
        TestStep.wait(seconds: 2)

        TestStep.tmuxCapturePaneContent(target: "mouse-test:0", storeAs: "after-scroll-down")
        TestStep.log("After scroll down: ${after-scroll-down}")
        TestStep.assertStoredContains(key: "after-scroll-down", substring: "SCROLL:-")

        // ── Test scroll up ───────────────────────────────────────
        TestStep.log("Sending scroll-up events")
        TestStep.macScrollWheel(deltaY: 3, count: 10)
        TestStep.wait(seconds: 2)

        TestStep.tmuxCapturePaneContent(target: "mouse-test:0", storeAs: "after-scroll-up")
        TestStep.log("After scroll up: ${after-scroll-up}")
        // Net scroll should now be positive (10 up - 5 down = +5)
        TestStep.assertStoredContains(key: "after-scroll-up", substring: "SCROLL:")
        TestStep.assertStoredNotContains(key: "after-scroll-up", substring: "SCROLL:0")
        TestStep.assertStoredNotContains(key: "after-scroll-up", substring: "SCROLL:-")
        TestStep.macScreenshot(label: "after-scroll")

        // ── Test click ───────────────────────────────────────────
        // Window is at (10, 10) with 250px sidebar, 1000×600 total.
        // Terminal area starts around x=260. Click in the middle of
        // the terminal to verify click events arrive with coordinates.
        TestStep.log("Sending click event")
        TestStep.macClickAtPoint(x: 450, y: 200)
        TestStep.wait(seconds: 1)

        TestStep.tmuxCapturePaneContent(target: "mouse-test:0", storeAs: "after-click-1")
        TestStep.log("After first click: ${after-click-1}")
        TestStep.assertStoredContains(key: "after-click-1", substring: "CLICK:1")
        // Position should be non-zero (proves coordinates were decoded)
        TestStep.assertStoredNotContains(key: "after-click-1", substring: "CLICK-COL:0")
        TestStep.assertStoredNotContains(key: "after-click-1", substring: "CLICK-ROW:0")

        // ── Test second click at different position ──────────────
        TestStep.log("Sending second click at different position")
        TestStep.macClickAtPoint(x: 650, y: 350)
        TestStep.wait(seconds: 1)

        TestStep.tmuxCapturePaneContent(target: "mouse-test:0", storeAs: "after-click-2")
        TestStep.log("After second click: ${after-click-2}")
        TestStep.assertStoredContains(key: "after-click-2", substring: "CLICK:2")
        TestStep.macScreenshot(label: "after-clicks")

        // ── Verify motion doesn't cause clicks ──────────────────
        // The click count should still be 2 — mouse movement over
        // the window during scroll events did not increment it.
        TestStep.assertStoredNotContains(key: "after-click-2", substring: "CLICK:3")

        // ── Cleanup ──────────────────────────────────────────────
        TestStep.tmuxSendKeys(target: "mouse-test:0", keys: "C-c")
        TestStep.wait(seconds: 1)
        Shortcut.tmuxRunCommand(target: "mouse-helper:0", command: "rm -f /tmp/mouse_test.py")
    }
}

// swiftlint:enable function_body_length
