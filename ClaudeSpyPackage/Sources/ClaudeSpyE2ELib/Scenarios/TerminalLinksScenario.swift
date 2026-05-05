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
        // overlay should change. Both the iOS and macOS screenshots below
        // use the default `compare: true` to actively verify the underlines
        // disappeared — a regression that re-introduces them on either
        // platform would fail here. iOS first, since it currently has focus.
        TestStep.iosScreenshot(label: "ios-terminal-links-mouse-mode")

        // Re-assert the standard Panes-window sizing so both macOS captures
        // share dimensions. We can't reuse `Shortcut.openPanesWindow()` here
        // because once `links-test` is selected, MainView's navigationTitle
        // becomes the session's primary label (e.g. "~") instead of
        // "Gallager", and the shortcut's `macWaitForWindow(titled: "Gallager")`
        // would time out. The window is already open from the earlier call,
        // so we just reapply the geometry directly.
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_000, height: 600)
        TestStep.macSetSidebarWidth(250)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "links-test")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-terminal-links-mouse-mode")

        // Disable mouse mode again so we don't bleed state into later scenarios.
        Shortcut.tmuxRunCommand(
            target: "links-test:0",
            command: #"printf '\e[?1002l'"#
        )
        TestStep.wait(seconds: 0.5)

        // ── Verify URL underline doesn't extend past the URL when right-aligned
        // content is present on the same line (issue #462) ───────────────────
        //
        // Reproduction: a shell prompt theme that draws the previous command's
        // exit code on the right side of the same line as the next prompt
        // (zsh's RPROMPT, oh-my-zsh's "robbyrussell", powerlevel10k, etc.) uses
        // cursor positioning to write the right-aligned text, leaving the
        // cells between the typed content and the right text uninitialized.
        // SwiftTerm's `BufferLine.translateToString` returns NULL chars for
        // those cells. Without the fix, the URL regex runs through the NULL
        // cells into the right-aligned text, painting the link underline
        // across the whole line.
        //
        // We construct that line state directly with `printf`:
        //   - clear the screen so all cells are uninitialized (code = 0)
        //   - print the prompt + URL at the start of row 1
        //   - jump to col 118 and write "130" (the fake exit code)
        //   - return cursor near the end of "repo" (where the user would be
        //     mid-typing — matches the original screenshot)
        //   - hold the foreground so the shell prompt doesn't reappear and
        //     overwrite our carefully-constructed buffer state
        //
        // After the fix, the underline ends at the URL boundary; before, it
        // would stretch all the way to "130" on the right.

        TestStep.log("Reproducing #462: URL underline extending past URL when right-aligned content present")
        Shortcut.tmuxRunCommand(
            target: "links-test:0",
            command: #"clear; printf '$ git clone http://github.com/idonotexist/repo'; printf '\e[118G130'; printf '\r\e[46C'; cat >/dev/null"#
        )
        TestStep.wait(seconds: 2)

        // Capture the same regression on iOS — both platforms share
        // `TerminalURLDetector`, so a re-introduction here would otherwise
        // slip through. iOS is already focused on the `links-test` terminal
        // from the earlier mouse-mode check.
        TestStep.iosScreenshot(label: "ios-terminal-links-rprompt-462")

        // Re-select the pane so the macOS view definitely reflects the new
        // tmux state (the prior screenshot left it focused, but a paint pass
        // tied to selection ensures the underline overlay is recomputed).
        TestStep.macClickButton(titled: "links-test")
        TestStep.wait(seconds: 1)

        // Baseline asserts the post-fix appearance: the URL underline ends
        // right after "repo", with the "130" on the right rendered plainly.
        TestStep.macScreenshot(label: "mac-terminal-links-rprompt-462")

        // Send Ctrl-C to terminate `cat` and return to a fresh prompt for
        // any later scenarios sharing this pane.
        TestStep.tmuxSendKeys(target: "links-test:0", keys: "C-c")
        TestStep.wait(seconds: 0.5)
    }
}
