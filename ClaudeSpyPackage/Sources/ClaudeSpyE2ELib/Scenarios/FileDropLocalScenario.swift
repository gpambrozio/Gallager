import Foundation

/// E2E scenario: dropping files on a local terminal pane pastes the
/// shell-escaped paths via tmux's bracketed-paste buffer.
///
/// Three things to assert:
/// 1. While the in-pane app has bracketed-paste mode (DEC 2004) on, the
///    paths arrive wrapped in `ESC[200~ … ESC[201~` markers — this is the
///    whole point of `paste-buffer -p`.
/// 2. Filenames with spaces are shell-escaped with backslashes, matching
///    Terminal.app's drop format that Claude Code already round-trips.
/// 3. After the in-pane app exits and bracketed-paste mode is disabled,
///    a follow-up drop still pastes the path verbatim — the buffer is
///    just text, not magic.
public enum FileDropLocalScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "File Drop Local",
        tags: ["drag-and-drop", "macos-only"]
    ) {
        // ── Setup ───────────────────────────────────────────────────
        Shortcut.macOnlySetup

        TestStep.tmuxCreateSession(name: "drop-local", width: 80, height: 24)
        TestStep.wait(seconds: 2)

        TestStep.macWaitForElement(titled: "drop-local", timeout: 10)
        TestStep.macClickButton(titled: "drop-local")
        TestStep.wait(seconds: 2)

        // The pane must be present and addressable in the AX tree before
        // we kick off the drop simulation — without it the test endpoint
        // can't find an `InteractiveTerminalView` to dispatch to.
        TestStep.macWaitForElementQuery(
            .identifier("terminal-%0"),
            timeout: 15
        )

        // ── Bracketed-paste leg ────────────────────────────────────
        // Drop two files, one of which has a space in the name. The
        // listener should see both paths joined by a space (with the
        // middle one's space backslash-escaped) wrapped in CSI 200~/201~.
        TestStep.injectScript(name: "bracketed_paste_listener.py")
        Shortcut.tmuxRunCommand(
            target: "drop-local:0",
            command: "python3 $TMPDIR/bracketed_paste_listener.py"
        )
        // Give the listener time to run termios setup + emit
        // `BRACKETED_LISTENER_READY` so the paste lands while it's already
        // blocked on stdin.
        TestStep.wait(seconds: 2)

        // Drop two files — one with a space, one plain.
        TestStep.macDropFilesOnPane(
            paneId: "%0",
            paths: ["/tmp/Drop Me.txt", "/tmp/dropme2.txt"]
        )

        // Wait for the listener to capture the paste, print the marker,
        // and exit so we can capture stable pane output.
        TestStep.wait(seconds: 4)

        TestStep.tmuxCapturePaneContent(
            target: "drop-local:0",
            storeAs: "drop.bracketed"
        )
        TestStep.assertStoredContains(
            key: "drop.bracketed",
            substring: "PASTED:/tmp/Drop\\ Me.txt /tmp/dropme2.txt"
        )
        TestStep.assertStoredNotContains(
            key: "drop.bracketed",
            substring: "NO_PASTE"
        )

        // ── Non-bracketed leg ──────────────────────────────────────
        // The listener has exited; the shell is now reading directly.
        // Drop a single file and confirm the (escaped) path is typed
        // into the shell's input buffer the same way it would be on a
        // terminal that doesn't advertise bracketed-paste mode.
        TestStep.wait(seconds: 1)
        TestStep.macDropFilesOnPane(
            paneId: "%0",
            paths: ["/tmp/plain.txt"]
        )
        TestStep.wait(seconds: 2)

        TestStep.tmuxCapturePaneContent(
            target: "drop-local:0",
            storeAs: "drop.unbracketed"
        )
        // The shell echoes typed input by default; we should see the
        // escaped path on a line near the prompt without any CSI 200~
        // bracketed-paste prefix (since the shell never enabled it).
        TestStep.assertStoredContains(
            key: "drop.unbracketed",
            substring: "/tmp/plain.txt"
        )
        TestStep.assertStoredNotContains(
            key: "drop.unbracketed",
            substring: "\u{1B}[200~"
        )
    }
}
