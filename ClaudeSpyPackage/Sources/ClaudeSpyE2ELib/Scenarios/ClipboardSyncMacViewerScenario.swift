import Foundation

/// E2E scenario: Mac viewer clipboard sync via OSC 52
///
/// Tests clipboard forwarding from host terminal to a Mac-to-Mac viewer:
/// 1. Pair two Mac apps (host + viewer)
/// 2. Create a tmux session on the host and start streaming on the viewer
/// 3. Send OSC 52 clipboard escape sequence from the host terminal
/// 4. Verify the Mac viewer's clipboard receives the content
public enum ClipboardSyncMacViewerScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Clipboard Sync Mac Viewer",
        tags: ["clipboard", "terminal", "macos-only"]
    ) {
        // ── Setup: Pair two Mac apps ─────────────────────────────
        Shortcut.twoMacPairing

        // ── Create session and open on both ──────────────────────
        TestStep.tmuxCreateSession(name: "clip-mac", width: 80, height: 24)
        TestStep.wait(seconds: 2)

        // Open host panes window and select the session
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "clip-mac", timeout: 10)
        TestStep.macClickButton(titled: "clip-mac")
        TestStep.wait(seconds: 3)

        // Open viewer panes window and select the session
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macWaitForElement(titled: "clip-mac", timeout: 10, instance: 1)
        TestStep.macClickButton(titled: "clip-mac", instance: 1)
        TestStep.wait(seconds: 3)

        // Wait for the viewer to be streaming the terminal
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("$")]),
            timeout: 15,
            instance: 1
        )

        // ═══════════════════════════════════════════════════════════
        // Phase 1: Mac viewer clipboard sync
        // ═══════════════════════════════════════════════════════════

        TestStep.log("Phase 1: Mac viewer receives clipboard via OSC 52")

        // Send OSC 52 clipboard escape sequence from the host terminal
        // "mac viewer clipboard" in base64 = "bWFjIHZpZXdlciBjbGlwYm9hcmQ="
        Shortcut.tmuxRunCommand(
            target: "clip-mac:0.0",
            command: "printf '\\e]52;c;bWFjIHZpZXdlciBjbGlwYm9hcmQ=\\a'"
        )
        TestStep.wait(seconds: 3)

        // Read the viewer's clipboard and verify
        TestStep.macReadClipboard(storeAs: "macViewerClipboard", instance: 1)
        TestStep.assertStoredContains(key: "macViewerClipboard", substring: "mac viewer clipboard")
    }
}
