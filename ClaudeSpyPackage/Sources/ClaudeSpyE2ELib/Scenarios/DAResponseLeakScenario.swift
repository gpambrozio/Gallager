import Foundation

/// E2E scenario: Verify that SwiftTerm's Device Attributes (DA) response does not leak
/// back into the tmux pane as typed input — on both macOS and iOS.
///
/// When the terminal emulator (SwiftTerm) receives a DA query (ESC[c) in the data stream,
/// it generates a response internally. This response must be suppressed — if it's forwarded
/// back (via local send-keys on macOS, or via the relay WebSocket on iOS), it appears as
/// garbage characters (e.g., "5;4;1;2;6;21;22;17;28c") typed into the shell prompt.
///
/// Note: tmux's own terminal also responds to DA queries with a short response (e.g.,
/// `ESC[?1;2;4c`). This is expected tmux behavior. The assertions check specifically for
/// SwiftTerm's longer response fragments (`;28c`, `;22;17`, `?65;`) which would only
/// appear if the SwiftTerm DA response leaked through.
///
/// This test:
/// 1. Pairs macOS and iOS, sets up a tmux pane mirrored on both
/// 2. Sends Primary DA queries (ESC[c) via printf
/// 3. Captures pane content and asserts no SwiftTerm DA response fragments leaked
public enum DAResponseLeakScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "DA Response Leak",
        tags: ["rendering"]
    ) {
        // ── Phase 1: Pair macOS host with iOS simulator ───────────────
        FreshPairingScenario.scenario

        // ── Phase 2: Create tmux session ──────────────────────────────
        TestStep.log("Creating tmux session for DA response leak test")
        TestStep.tmuxCreateSession(name: "e2e-da-leak", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        // ── Phase 3: Open pane on macOS host ──────────────────────────
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Available Windows", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 900, height: 500)
        TestStep.macSetSidebarWidth(200)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElement(titled: "e2e-da-leak:0", timeout: 10)
        TestStep.macClickButton(titled: "e2e-da-leak:0")
        TestStep.wait(seconds: 2)

        // Clear screen to have a clean baseline
        TestStep.tmuxSendKeys(target: "e2e-da-leak:0", keys: "clear", literal: true)
        TestStep.tmuxSendKeys(target: "e2e-da-leak:0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // ── Phase 4: Test Primary DA with macOS only ──────────────────
        // At this point only the macOS SwiftTerm is mirroring the pane.
        TestStep.log("Sending Primary DA query (ESC[c) — macOS mirror active")
        TestStep.tmuxSendKeys(
            target: "e2e-da-leak:0",
            keys: #"printf '\e[c' && sleep 1 && echo MAC_DA1_DONE"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "e2e-da-leak:0", keys: "Enter")
        TestStep.wait(seconds: 3)

        TestStep.tmuxCapturePaneContent(target: "e2e-da-leak:0", storeAs: "macDA1")
        TestStep.assertStoredContains(key: "macDA1", substring: "MAC_DA1_DONE")
        // SwiftTerm DA response: ESC[?65;1;2;6;21;22;17;28c
        // These fragments are unique to SwiftTerm and won't match tmux's own
        // shorter DA response (ESC[?1;2;4c).
        TestStep.assertStoredNotContains(key: "macDA1", substring: ";28c")
        TestStep.assertStoredNotContains(key: "macDA1", substring: ";22;17")
        TestStep.assertStoredNotContains(key: "macDA1", substring: "?65;")

        TestStep.macScreenshot(label: "mac-after-da1", compare: false)

        // ── Phase 5: Open pane on iOS ─────────────────────────────────
        // Now the iOS SwiftTerm will also mirror the pane, adding a second
        // source of potential DA response leakage via the relay WebSocket.
        TestStep.log("Opening pane on iOS viewer")
        TestStep.iosWaitForElement(.labelContains("e2e-da-leak"), timeout: 15)
        TestStep.iosTap(.labelContains("e2e-da-leak"))
        TestStep.wait(seconds: 3)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
        TestStep.wait(seconds: 3)

        // Clear screen before the combined test
        TestStep.tmuxSendKeys(target: "e2e-da-leak:0", keys: "clear", literal: true)
        TestStep.tmuxSendKeys(target: "e2e-da-leak:0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // ── Phase 6: Test Primary DA with both mirrors active ─────────
        // Both macOS and iOS SwiftTerm instances process the DA query.
        // If either leaks, we'll see response fragments in the pane.
        TestStep.log("Sending Primary DA query (ESC[c) — both mirrors active")
        TestStep.tmuxSendKeys(
            target: "e2e-da-leak:0",
            keys: #"printf '\e[c' && sleep 1 && echo BOTH_DA1_DONE"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "e2e-da-leak:0", keys: "Enter")
        TestStep.wait(seconds: 3)

        TestStep.tmuxCapturePaneContent(target: "e2e-da-leak:0", storeAs: "bothDA1")
        TestStep.assertStoredContains(key: "bothDA1", substring: "BOTH_DA1_DONE")
        TestStep.assertStoredNotContains(key: "bothDA1", substring: ";28c")
        TestStep.assertStoredNotContains(key: "bothDA1", substring: ";22;17")
        TestStep.assertStoredNotContains(key: "bothDA1", substring: "?65;")

        TestStep.macScreenshot(label: "both-after-da1", compare: false)
        TestStep.iosScreenshot(label: "ios-after-da1", compare: false)
    }
}
