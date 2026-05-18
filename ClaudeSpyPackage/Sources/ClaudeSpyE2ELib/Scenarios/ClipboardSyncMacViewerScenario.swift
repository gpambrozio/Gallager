import Foundation

/// E2E scenario: Mac viewer clipboard sync via OSC 52
///
/// Tests clipboard forwarding from host terminal to a Mac-to-Mac viewer:
/// 1. Pair two Mac apps (host + viewer), create and stream a tmux session
/// 2. **Positive**: Send OSC 52 while viewer terminal is key — clipboard syncs
/// 3. **Negative**: Open Settings to defocus terminal, send OSC 52 — clipboard unchanged
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

        // Wait for the viewer to be streaming the terminal
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("$")]),
            timeout: 15,
            instance: 1
        )

        // ═══════════════════════════════════════════════════════════
        // Phase 1: Positive — clipboard synced when viewer is focused
        // ═══════════════════════════════════════════════════════════

        TestStep.log("Phase 1: Mac viewer receives clipboard via OSC 52")

        // Ensure the viewer is frontmost with its terminal window key —
        // applyClipboardIfFocused guards on NSApp.isActive and isKeyWindow.
        TestStep.macActivate(instance: 1)

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

        // ═══════════════════════════════════════════════════════════
        // Phase 2: Negative — clipboard NOT synced when terminal
        // window is not key
        // ═══════════════════════════════════════════════════════════

        TestStep.log("Phase 2: Clipboard NOT synced when viewer's terminal window loses focus")

        // Open Settings on the viewer — this steals key window from the terminal
        // The Settings window is already open from pairing setup with "Remote Hosts" tab
        TestStep.macOpenSettings(instance: 1)
        TestStep.macWaitForWindow(titled: "Remote Hosts", timeout: 5, instance: 1)
        TestStep.wait(seconds: 2)

        // Send another OSC 52 while the terminal window is not key
        // "should not arrive mac" in base64 = "c2hvdWxkIG5vdCBhcnJpdmUgbWFj"
        Shortcut.tmuxRunCommand(
            target: "clip-mac:0.0",
            command: "printf '\\e]52;c;c2hvdWxkIG5vdCBhcnJpdmUgbWFj\\a'"
        )
        TestStep.wait(seconds: 3)

        // Clipboard should still have the Phase 1 value, NOT the new one
        TestStep.macReadClipboard(storeAs: "macClipboardAfter", instance: 1)
        TestStep.assertStoredNotContains(key: "macClipboardAfter", substring: "should not arrive mac")
        TestStep.assertStoredContains(key: "macClipboardAfter", substring: "mac viewer clipboard")
    }
}
