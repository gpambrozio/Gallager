import Foundation

/// E2E scenario: pasting an image on a Mac viewer forwards it to the Mac host.
///
/// 1. Pair two Mac apps (host + viewer) and create a tmux session.
/// 2. Start `ctrl_v_listener.py` in the host pane so the foreground process
///    blocks on stdin and can detect a Ctrl+V byte the moment it lands.
/// 3. Place a small known PNG on the viewer's file-backed clipboard.
/// 4. Press Cmd+V on the viewer's remote terminal mirror.
/// 5. Verify two things end-to-end:
///    - the image arrives on the host's pasteboard with byte-for-byte parity,
///    - the listener prints `CTRL_V_RECEIVED`, proving the host handler
///      also dispatches `Ctrl+V` into the target tmux pane (so a real
///      foreground app like Claude Code would read the pasteboard).
public enum ImagePasteRemoteScenario {
    /// Smallest valid PNG: a 1×1 fully-transparent pixel. Hard-coded so the
    /// scenario stays self-contained and the byte stream we assert against
    /// is deterministic.
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
        // and ready to receive the synthesized Ctrl+V from the relay.
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

        // ── Paste flow ──────────────────────────────────────────────
        TestStep.log("Placing PNG on viewer clipboard and pressing Cmd+V")

        // Stash the original bytes so the assertion can compare exact equality.
        TestStep.storeValue(key: "imagePaste.original", value: samplePNGBase64)
        TestStep.storeValue(key: "imagePaste.empty", value: "")

        // Clear clipboards on both sides so prior scenarios don't leak state —
        // the host's image clipboard must start empty so the post-paste read
        // proves `SendImage` actually wrote something.
        TestStep.macClearClipboard(instance: 0)
        TestStep.macClearClipboard(instance: 1)
        TestStep.macReadClipboardImage(storeAs: "imagePaste.preHost", instance: 0)
        TestStep.assertStoredEqual(
            key: "imagePaste.preHost",
            otherKey: "imagePaste.empty"
        )

        // Place the PNG on the viewer's clipboard.
        TestStep.macWriteClipboardImage(
            base64: samplePNGBase64,
            format: "png",
            instance: 1
        )

        // Start a Ctrl+V listener in the host pane *before* the paste is
        // dispatched, so the foreground process is already blocked on
        // stdin when the host handler synthesises Ctrl+V. The listener
        // prints `CTRL_V_RECEIVED` and exits on hit, or `NO_CTRL_V` on a
        // 10s idle timeout — either way we get a deterministic marker
        // we can grep from the captured pane content.
        TestStep.injectScript(name: "ctrl_v_listener.py")
        Shortcut.tmuxRunCommand(
            target: "image-paste:0",
            command: "python3 $TMPDIR/ctrl_v_listener.py"
        )
        TestStep.wait(seconds: 1)

        // Activate the viewer so its terminal NSWindow is key — Cmd+V is
        // routed by `performKeyEquivalent`, which only fires on the focused
        // pane. Without this guard a sibling Settings window can swallow
        // the keystroke after a prior scenario steals focus.
        TestStep.macActivate(instance: 1)
        TestStep.wait(seconds: 1)

        // Send Cmd+V on the viewer. The image clipboard branch of
        // `InteractiveTerminalView.performKeyEquivalent` should pick up the
        // PNG and dispatch a SendImage command via the relay.
        TestStep.macPaste(instance: 1)

        // Wait for the relay round-trip, the host's pasteboard write, the
        // synthesised Ctrl+V into the pane, and the listener's print +
        // exit before we capture the pane content.
        TestStep.wait(seconds: 6)

        // ── Verify the host pasteboard has the same PNG bytes ───────
        TestStep.macReadClipboardImage(storeAs: "imagePaste.host", instance: 0)
        TestStep.assertStoredEqual(
            key: "imagePaste.host",
            otherKey: "imagePaste.original"
        )

        // ── Verify the host pane received Ctrl+V ────────────────────
        TestStep.tmuxCapturePaneContent(
            target: "image-paste:0",
            storeAs: "imagePaste.paneContent"
        )
        TestStep.assertStoredContains(
            key: "imagePaste.paneContent",
            substring: "CTRL_V_RECEIVED"
        )
        TestStep.assertStoredNotContains(
            key: "imagePaste.paneContent",
            substring: "NO_CTRL_V"
        )
    }
}
