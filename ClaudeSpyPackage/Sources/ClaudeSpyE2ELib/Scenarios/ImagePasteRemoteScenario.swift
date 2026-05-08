import Foundation

/// E2E scenario: pasting an image on a Mac viewer forwards it to the Mac host.
///
/// Image paste rides the same `SendDroppedFiles` flow Finder drops use — the
/// viewer wraps the clipboard image as a single synthetic `pasted-image-<UUID>.<ext>`
/// file, the host saves it under `$TMPDIR/gallager-drop-<UUID>/`, and the
/// resolved path is bracketed-pasted into the target tmux pane via
/// `tmux load-buffer` + `paste-buffer -p`.
///
/// 1. Pair two Mac apps (host + viewer) and create a tmux session.
/// 2. Place a small known PNG on the viewer's file-backed clipboard.
/// 3. Start `bracketed_paste_listener.py` in the host pane so DEC mode 2004
///    is enabled when the relay round-trip completes.
/// 4. Press Cmd+V on the viewer's remote terminal mirror.
/// 5. Verify the listener captured a paste whose payload mentions both the
///    `gallager-drop-` landing prefix and a `pasted-image-…png` filename,
///    proving the image was saved and its path was bracketed-pasted.
public enum ImagePasteRemoteScenario {
    /// Smallest valid PNG: a 1×1 fully-transparent pixel. Hard-coded so the
    /// scenario stays self-contained.
    private static let samplePNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Image Paste Remote",
        tags: ["clipboard", "image", "macos-only"]
    ) {
        // ── Setup: pair two Mac apps ────────────────────────────────
        Shortcut.twoMacPairing

        // ── Create tmux session and stream it on both sides ─────────
        TestStep.tmuxCreateSession(name: "image-paste", width: 80, height: 24)
        TestStep.wait(seconds: 2)

        // Open the host's panes window so the host's terminal mirror is up
        // and ready to receive the synthesized paste.
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "image-paste", timeout: 10)
        TestStep.macClickButton(titled: "image-paste")
        TestStep.wait(seconds: 2)

        // Open the viewer's panes window and select the same session.
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macWaitForElement(titled: "image-paste", timeout: 10, instance: 1)
        TestStep.macClickButton(titled: "image-paste", instance: 1)
        TestStep.wait(seconds: 3)

        // Confirm the viewer's terminal is fully attached to the stream
        // before we paste — without this, a Cmd+V dispatched too early can
        // be dropped by SwiftTerm during initial-state apply.
        TestStep.macWaitForElementQuery(
            .identifier("terminal-%0"),
            timeout: 15,
            instance: 1
        )

        // ── Place PNG on viewer's clipboard ─────────────────────────
        TestStep.log("Placing PNG on viewer clipboard and pressing Cmd+V")

        // Clear both clipboards so prior scenarios can't leak state.
        TestStep.macClearClipboard(instance: 0)
        TestStep.macClearClipboard(instance: 1)

        // Place the PNG on the viewer's clipboard.
        TestStep.macWriteClipboardImage(
            base64: samplePNGBase64,
            format: "png",
            instance: 1
        )

        // ── Bracketed-paste leg ────────────────────────────────────
        // Start the listener *before* the paste so DEC mode 2004 is set
        // when the relay round-trip lands. The listener prints
        // `PASTED:<payload>` on the first bracketed paste it sees and
        // exits, or `NO_PASTE` on a 10s timeout.
        TestStep.injectScript(name: "bracketed_paste_listener.py")
        Shortcut.tmuxRunCommand(
            target: "image-paste:0",
            command: "python3 $TMPDIR/bracketed_paste_listener.py"
        )
        TestStep.wait(seconds: 2)

        // Activate the viewer so its terminal NSWindow is key — Cmd+V is
        // routed by `performKeyEquivalent`, which only fires on the focused
        // pane.
        TestStep.macActivate(instance: 1)
        TestStep.wait(seconds: 1)

        // Send Cmd+V on the viewer. The image clipboard branch of
        // `InteractiveTerminalView.performKeyEquivalent` should pick up the
        // PNG, wrap it as a synthetic `DroppedFile`, and ship it via
        // `SendDroppedFiles`.
        TestStep.macPaste(instance: 1)

        // Wait for the relay round-trip + load-buffer/paste-buffer +
        // listener exit before capturing.
        TestStep.wait(seconds: 6)

        TestStep.tmuxCapturePaneContent(
            target: "image-paste:0",
            storeAs: "imagePaste.bracketed"
        )
        // The listener prints `PASTED:` followed by the bytes between
        // `ESC[200~` and `ESC[201~`, which should be the host-side
        // `gallager-drop-<UUID>/pasted-image-<UUID>.png` path produced by
        // `DroppedPathFormatter`.
        TestStep.assertStoredContains(
            key: "imagePaste.bracketed",
            substring: "PASTED:"
        )
        TestStep.assertStoredContains(
            key: "imagePaste.bracketed",
            substring: "gallager-drop-"
        )
        TestStep.assertStoredContains(
            key: "imagePaste.bracketed",
            substring: "pasted-image-"
        )
        TestStep.assertStoredContains(
            key: "imagePaste.bracketed",
            substring: ".png"
        )
        TestStep.assertStoredNotContains(
            key: "imagePaste.bracketed",
            substring: "NO_PASTE"
        )
    }
}
