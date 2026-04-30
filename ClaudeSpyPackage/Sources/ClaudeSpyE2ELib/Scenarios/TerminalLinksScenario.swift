import Foundation

/// E2E scenario: Verify terminal link detection on macOS and iOS
///
/// Tests both plain-text URL detection (via regex) and OSC 8 hyperlink escape
/// sequence detection. Verifies that links are visible (underlined) in mirrored
/// terminal sessions on both macOS and iOS, and that the underlines disappear
/// once the host enables mouse tracking — since the remote terminal app then
/// owns clicks, links must not look interactive.
///
/// **Setup:** Pairs devices first, then creates a tmux session, emits plain-text
/// URLs and OSC 8 hyperlinks, and verifies they render on both macOS and iOS.
///
/// **OSC 8 format:** `\e]8;;URL\e\\LINK_TEXT\e]8;;\e\\`
/// The escape sequence attaches a hyperlink URL to the visible LINK_TEXT.
public enum TerminalLinksScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal Links",
        tags: ["terminal", "links"]
    ) {
        // ── Pair devices first ──────────────────────────────────────
        // Pairing launches both apps and establishes the relay connection.
        // Do this before creating tmux sessions so the session survives
        // app restarts during the pairing flow.

        FreshPairingScenario.scenario

        // ── Setup tmux session ──────────────────────────────────────

        TestStep.log("Creating tmux session for link testing")
        TestStep.tmuxCreateSession(name: "links-test", width: 120, height: 40)

        // Set a plain prompt to avoid shell color codes interfering with link rendering
        Shortcut.tmuxClearAndSetPrompt(target: "links-test:0")

        // ── Emit URLs ───────────────────────────────────────────────

        // 1. Plain-text URL (detected by regex)
        Shortcut.tmuxRunCommand(
            target: "links-test:0",
            command: #"echo 'Plain URL: https://example.com/plain-link'"#
        )
        TestStep.wait(seconds: 0.3)

        // 2. OSC 8 hyperlink escape sequence
        // Format: \e]8;;URL\e\\VISIBLE_TEXT\e]8;;\e\\
        // Using \a (BEL) as string terminator since tmux handles it more reliably
        Shortcut.tmuxRunCommand(
            target: "links-test:0",
            command: #"printf 'OSC8 link: \e]8;;https://example.com/osc8-link\aClick Here\e]8;;\a\n'"#
        )
        TestStep.wait(seconds: 0.3)

        // 3. OSC 8 link where the visible text is also a URL (OSC 8 should take priority)
        Shortcut.tmuxRunCommand(
            target: "links-test:0",
            command: #"printf 'Dual link: \e]8;;https://example.com/real-target\ahttps://example.com/visible-url\e]8;;\a\n'"#
        )
        TestStep.wait(seconds: 0.5)

        // ── Verify on macOS ─────────────────────────────────────────

        TestStep.log("Verifying links on macOS")
        Shortcut.openPanesWindow()
        TestStep.macResizeWindow(width: 1_200, height: 700)

        // Select the links-test pane
        TestStep.macClickButton(titled: "links-test")
        TestStep.wait(seconds: 2)

        // Screenshot showing links rendered with underlines on macOS
        TestStep.macScreenshot(label: "mac-terminal-links", compare: false)

        // ── Verify on iOS ───────────────────────────────────────────

        TestStep.log("Verifying links on iOS")

        // After pairing, the existing links-test session is already visible in the iOS session list.
        // Tap on it to open the terminal view — no need to create a new terminal.
        TestStep.iosWaitForElement(.labelContains("links-test"), timeout: 15)
        TestStep.iosTap(.labelContains("links-test"))
        TestStep.wait(seconds: 3)

        // Screenshot showing links rendered with underlines on iOS
        TestStep.iosScreenshot(label: "ios-terminal-links", compare: false)

        // ── Verify underlines disappear once mouse mode is active ──
        // Enabling SGR mouse tracking (DECSET 1002) flips the host terminal
        // into the state TUI apps like Claude Code use. While that's active
        // the remote app owns clicks, so neither the macOS nor the iOS viewer
        // should keep rendering link underlines (which would suggest the
        // links are still interactive). The encoding is omitted purely to
        // keep the typed command short.

        TestStep.log("Enabling mouse mode and verifying underlines disappear")
        Shortcut.tmuxRunCommand(
            target: "links-test:0",
            command: #"printf '\e[?1002h'"#
        )
        TestStep.wait(seconds: 1)

        // Same three URL lines remain in the buffer; only the underline
        // overlay should change. iOS first, since it currently has focus.
        TestStep.iosScreenshot(label: "ios-terminal-links-mouse-mode", compare: false)

        // Refocus the macOS Panes window. The "links-test" session is still
        // selected from earlier, so the window title now reflects its primary
        // sidebar label ("~" — the abbreviated home directory) rather than
        // the default "Gallager" fallback.
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "~", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "links-test")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-terminal-links-mouse-mode", compare: false)

        // Disable mouse mode again so we don't bleed state into later scenarios.
        Shortcut.tmuxRunCommand(
            target: "links-test:0",
            command: #"printf '\e[?1002l'"#
        )
        TestStep.wait(seconds: 0.5)
    }
}
