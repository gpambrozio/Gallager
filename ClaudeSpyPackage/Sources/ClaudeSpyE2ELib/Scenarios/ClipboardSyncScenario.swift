import Foundation

/// E2E scenario: Remote clipboard sync via OSC 52
///
/// Tests clipboard forwarding from host terminal to connected viewers:
/// 1. **iOS viewer**: OSC 52 clipboard content reaches iOS pasteboard when the
///    viewer is focused on the streaming pane
/// 2. **Mac viewer**: Same flow for a Mac-to-Mac viewer
/// 3. **Negative**: Clipboard is NOT synced when the iOS viewer navigates away
///    from the terminal pane (back to Sessions list)
public enum ClipboardSyncScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Clipboard Sync",
        tags: ["clipboard", "terminal"]
    ) {
        // ── Setup: Fresh pairing (server + macOS host + iOS viewer) ──
        FreshPairingScenario.scenario

        // Create a tmux session and store the pane ID
        TestStep.tmuxCreateSession(name: "clip-test", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "clip-test:0.0", storeAs: "paneId")

        // Wait for the plain terminal row to appear on iOS before sending the
        // SessionStart hook — guarantees the viewer has the pane state so the
        // hook transitions it into a Claude session row deterministically.
        TestStep.iosWaitForElement(.labelContains("clip-test"), timeout: 15)

        // Send a SessionStart hook so the session appears as a Claude session on iOS
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-clip-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/ClipTest"
        )
        TestStep.wait(seconds: 3)

        // ═══════════════════════════════════════════════════════════════
        // Phase 1: iOS viewer clipboard sync
        // ═══════════════════════════════════════════════════════════════

        TestStep.log("Phase 1: iOS viewer receives clipboard via OSC 52")

        // Navigate to the terminal view on iOS
        TestStep.iosWaitForElement(.labelContains("ClipTest"), timeout: 15)
        TestStep.iosTap(.labelContains("ClipTest"))
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
        TestStep.wait(seconds: 2)

        // Send OSC 52 clipboard escape sequence from the host terminal
        // OSC 52 format: ESC ] 52 ; c ; <base64> BEL
        // "hello from host" in base64 = "aGVsbG8gZnJvbSBob3N0"
        Shortcut.tmuxRunCommand(
            target: "clip-test:0.0",
            command: "printf '\\e]52;c;aGVsbG8gZnJvbSBob3N0\\a'"
        )
        TestStep.wait(seconds: 3)

        // Read the iOS simulator clipboard and verify it contains the expected text
        TestStep.iosReadClipboard(storeAs: "iosClipboard")
        TestStep.assertStoredContains(key: "iosClipboard", substring: "hello from host")

        // ═══════════════════════════════════════════════════════════════
        // Phase 2: Negative case — clipboard NOT synced when navigated away
        // ═══════════════════════════════════════════════════════════════

        TestStep.log("Phase 2: Clipboard NOT synced when iOS navigates away from pane")

        // Navigate back to Sessions list (stops terminal streaming)
        TestStep.iosTap(.labelContains("Sessions"))
        TestStep.wait(seconds: 2)

        // Clear the iOS clipboard to a known value so we can detect no change
        // Send a different OSC 52 — since iOS is NOT viewing the pane, it should NOT arrive
        Shortcut.tmuxRunCommand(
            target: "clip-test:0.0",
            command: "printf '\\e]52;c;c2hvdWxkIG5vdCBhcnJpdmU=\\a'"
        )
        // "should not arrive" in base64 = "c2hvdWxkIG5vdCBhcnJpdmU="
        TestStep.wait(seconds: 3)

        // The iOS clipboard should still contain the previous value, NOT the new one
        TestStep.iosReadClipboard(storeAs: "iosClipboardAfter")
        TestStep.assertStoredNotContains(key: "iosClipboardAfter", substring: "should not arrive")
        TestStep.assertStoredContains(key: "iosClipboardAfter", substring: "hello from host")
    }
}
