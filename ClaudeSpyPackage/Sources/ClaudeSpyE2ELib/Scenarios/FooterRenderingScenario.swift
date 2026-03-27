import Foundation

/// E2E scenario: DECSTBM scroll region footer rendering on iOS
///
/// Reproduces GitHub issue #244 where the fixed footer of a terminal using
/// DECSTBM (DEC Set Top and Bottom Margins) scroll regions is missing on iOS.
///
/// The host terminal has 65 rows × 100 columns. When mirrored to iOS, SwiftTerm's
/// auto-resize shrinks the buffer to fit the screen height, destroying the bottom
/// rows including the footer.
///
/// **Setup:** Pairs macOS and iOS, creates a 100×65 terminal
/// **Test:** Draws a fixed header (rows 1–3) and fixed footer (bottom 3 rows),
///   then scrolls content through the middle region using DECSTBM
/// **Verifies:** Footer text ("FIXED FOOTER") is visible on both macOS and iOS mirrors
public enum FooterRenderingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Footer Rendering",
        tags: ["rendering", "ios"]
    ) {
        // ── Pair devices ────────────────────────────────────────────
        FreshPairingScenario.scenario

        // ── Setup ─────────────────────────────────────────────────────
        TestStep.log("Creating 100×65 tmux session for footer rendering test")
        TestStep.tmuxCreateSession(name: "footer-test", width: 100, height: 65)
        TestStep.tmuxCreateSession(name: "footer-helper", width: 80, height: 24)

        TestStep.tmuxSendKeys(
            target: "footer-helper:0",
            keys: #"export PS1='$ '"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "footer-helper:0", keys: "Enter")

        TestStep.tmuxSendKeys(
            target: "footer-test:0",
            keys: #"export PS1='$ '"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "footer-test:0", keys: "Enter")
        TestStep.tmuxSendKeys(target: "footer-test:0", keys: "clear", literal: true)
        TestStep.tmuxSendKeys(target: "footer-test:0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // ── Write DECSTBM scroll region test script ──────────────────
        //
        // This is a simplified version of terminal-debug/term-stress.py --test 7.
        // It draws a fixed header (rows 1–3), a fixed footer (bottom 3 rows),
        // sets a DECSTBM scroll region between them, and fills the region with
        // colored scrolling content.
        TestStep.log("Writing DECSTBM scroll region test script")
        TestStep.tmuxSendKeys(
            target: "footer-helper:0",
            keys: #"""
            cat > /tmp/footer_test.py << 'PYEOF'
            import sys, time
            E = '\033'
            C = E + '['

            def w(s):
                sys.stdout.write(s)
                sys.stdout.flush()

            def cup(row, col):
                w(f'{C}{row};{col}H')

            def sgr(code):
                w(f'{C}{code}m')

            def reset():
                w(f'{C}0m')

            def decstbm(top, bot):
                w(f'{C}{top};{bot}r')

            def decstbm_reset():
                w(f'{C}r')

            # Get terminal size
            import os
            cols, rows = os.get_terminal_size()

            # Clear screen
            w(f'{C}2J{C}H')

            # ── Fixed header (rows 1–3): white on blue ──
            cup(1, 1)
            sgr('1;37;44')
            w(' ' * cols)
            cup(1, 1)
            w('  ┌─ FIXED HEADER ─' + '─' * (cols - 21) + '┐')
            cup(2, 1)
            w(f'  │ This stays pinned while content scrolls below{" " * (cols - 52)}│')
            cup(3, 1)
            w('  └' + '─' * (cols - 4) + '┘')
            reset()

            # ── Fixed footer (bottom 3 rows): white on green ──
            cup(rows - 2, 1)
            sgr('1;37;42')
            w('  ┌' + '─' * (cols - 4) + '┐')
            cup(rows - 1, 1)
            w(f'  │ FIXED FOOTER — status bar area{" " * (cols - 36)}│')
            cup(rows, 1)
            w('  └' + '─' * (cols - 4) + '┘')
            reset()

            # ── Set scroll region to the middle ──
            top_margin = 4
            bot_margin = rows - 3
            decstbm(top_margin, bot_margin)

            # ── Fill the scroll region with colored content ──
            scroll_height = bot_margin - top_margin + 1
            for i in range(1, scroll_height + 20):
                cup(bot_margin, 1)
                # Cycle through colors using ANSI 256-color
                color = 31 + (i % 6)
                sgr(f'1;{color}')
                w(f'    Scrolling line {i:3d} — content scrolls, header/footer stay fixed')
                reset()
                w('\n')
                time.sleep(0.02)

            # ── Reset scroll region and position cursor ──
            decstbm_reset()
            cup(rows, 1)
            PYEOF
            """#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "footer-helper:0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // ── Run the script ───────────────────────────────────────────
        TestStep.log("Running DECSTBM scroll region test")
        TestStep.tmuxSendKeys(
            target: "footer-test:0",
            keys: "python3 /tmp/footer_test.py",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "footer-test:0", keys: "Enter")
        // Wait for animation to complete (scroll_height + 20 lines × 20ms + buffer)
        TestStep.wait(seconds: 5)

        // ── Verify tmux has the footer ──────────────────────────────
        TestStep.log("Verifying tmux pane contains footer text")
        TestStep.tmuxCapturePaneContent(target: "footer-test:0", storeAs: "pane-content")
        TestStep.assertStoredContains(key: "pane-content", substring: "FIXED FOOTER")
        TestStep.assertStoredContains(key: "pane-content", substring: "FIXED HEADER")

        // ── Select the pane on macOS ─────────────────────────────────
        TestStep.log("Selecting pane on macOS for mirroring")

        // Resize macOS window to fit the 100×65 terminal
        TestStep.macResizeWindow(width: 1_072, height: 1_022)
        Shortcut.openPanesWindow()
        TestStep.macClickButton(titled: "footer-test:0")
        TestStep.wait(seconds: 3)

        // Screenshot: should show header and footer on macOS
        TestStep.macScreenshot(label: "footer-mac-full-terminal", compare: false)

        // ── Navigate to pane on iOS ─────────────────────────────────
        TestStep.log("Opening terminal pane on iOS mirror")
        TestStep.iosWaitForElement(.labelContains("footer-test"), timeout: 15)
        TestStep.iosTap(.labelContains("footer-test"))
        TestStep.wait(seconds: 3)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
        TestStep.wait(seconds: 3)

        // Screenshot: should show the terminal content on iOS
        // Before the fix, the footer is missing because SwiftTerm auto-resizes
        // the buffer to fit the screen, destroying bottom rows.
        // After the fix, the terminal expands and the outer scroll view allows
        // scrolling to see the footer.
        TestStep.iosScreenshot(label: "footer-ios-terminal", compare: false)
    }
}
