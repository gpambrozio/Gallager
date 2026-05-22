import Foundation

/// E2E scenario: dropping files on a remote viewer's terminal forwards the
/// file *bytes* to the host, the host saves them under `$TMPDIR`, and the
/// resolved paths are pasted into the target tmux pane via the same
/// bracketed-paste buffer the local drop path uses.
///
/// This exercises the half of issue #486 that mirrors PR #487's image
/// paste flow: the viewer doesn't know what local paths look like on the
/// host, so it ships the contents and lets the host pick a `$TMPDIR`
/// landing site that the in-pane app can actually read.
public enum FileDropRemoteScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "File Drop Remote",
        tags: ["drag-and-drop", "macos-only"]
    ) {
        // ── Setup: pair two Mac apps ────────────────────────────────
        Shortcut.twoMacPairing

        TestStep.tmuxCreateSession(name: "drop-remote", width: 80, height: 24)
        TestStep.wait(seconds: 2)

        // Open the host's panes window so the host's terminal mirror is up
        // and ready to receive the synthesized paste.
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "drop-remote", timeout: 10)
        TestStep.macClickButton(titled: "drop-remote")
        TestStep.wait(seconds: 2)

        // Open the viewer's panes window and select the same session.
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macWaitForElement(titled: "drop-remote", timeout: 10, instance: 1)
        TestStep.macClickButton(titled: "drop-remote", instance: 1)

        // Confirm the viewer's terminal is fully attached to the stream
        // before we drop — without this, a drop dispatched too early can
        // race the initial-state apply.
        TestStep.macWaitForElementQuery(
            .identifier("terminal-%0"),
            timeout: 15,
            instance: 1
        )

        // ── Stage source files on the viewer's machine ──────────────
        // Both viewer and host run on the same Mac in E2E so a path
        // under /tmp is reachable from either side. The bytes still
        // round-trip through the relay because the viewer reads them,
        // ships them via SendDroppedFiles, and the host writes a
        // *fresh* copy under `gallager-drop-<UUID>/`.
        TestStep.tmuxCommand(arguments: [
            "run-shell",
            "printf 'hello-from-viewer\\n' > /tmp/gallager-drop-viewer-source.txt",
        ])
        TestStep.wait(seconds: 1)

        // ── Bracketed-paste leg ────────────────────────────────────
        TestStep.injectScript(name: "bracketed_paste_listener.py")
        Shortcut.tmuxRunCommand(
            target: "drop-remote:0",
            command: "python3 $TMPDIR/bracketed_paste_listener.py"
        )
        TestStep.wait(seconds: 2)

        // Activate the viewer so its terminal NSWindow is key — the test
        // endpoint dispatches on whichever app instance the orchestrator
        // is talking to, but window key state isn't strictly required
        // here because we bypass AppKit's drag pipeline.
        TestStep.macActivate(instance: 1)
        TestStep.wait(seconds: 1)

        // Drop the staged file on the *viewer*. The viewer reads the
        // bytes, ships them as SendDroppedFiles, the host writes a copy
        // to a private `gallager-drop-<UUID>` subdir, and pastes that
        // resolved path into the host's tmux pane.
        TestStep.macDropFilesOnPane(
            paneId: "%0",
            paths: ["/tmp/gallager-drop-viewer-source.txt"],
            instance: 1
        )

        // Wait for the relay round-trip + load-buffer/paste-buffer +
        // listener exit before capturing.
        TestStep.wait(seconds: 6)

        TestStep.tmuxCapturePaneContent(
            target: "drop-remote:0",
            storeAs: "drop.remoteBracketed"
        )
        // The host saves into a `gallager-drop-<UUID>` directory and
        // preserves the original filename, so the listener's payload
        // should mention both the directory prefix and the filename.
        TestStep.assertStoredContains(
            key: "drop.remoteBracketed",
            substring: "PASTED:"
        )
        TestStep.assertStoredContains(
            key: "drop.remoteBracketed",
            substring: "gallager-drop-"
        )
        TestStep.assertStoredContains(
            key: "drop.remoteBracketed",
            substring: "gallager-drop-viewer-source.txt"
        )
        TestStep.assertStoredNotContains(
            key: "drop.remoteBracketed",
            substring: "NO_PASTE"
        )

        // ── Non-bracketed leg ──────────────────────────────────────
        // Listener exited; shell prompt is reading directly. A second
        // remote drop should still type the resolved $TMPDIR path so
        // that apps without bracketed-paste mode still see the path.
        TestStep.wait(seconds: 1)
        TestStep.macDropFilesOnPane(
            paneId: "%0",
            paths: ["/tmp/gallager-drop-viewer-source.txt"],
            instance: 1
        )
        TestStep.wait(seconds: 4)

        TestStep.tmuxCapturePaneContent(
            target: "drop-remote:0",
            storeAs: "drop.remoteUnbracketed"
        )
        TestStep.assertStoredContains(
            key: "drop.remoteUnbracketed",
            substring: "gallager-drop-viewer-source.txt"
        )
        TestStep.assertStoredNotContains(
            key: "drop.remoteUnbracketed",
            substring: "\u{1B}[200~"
        )
    }
}
