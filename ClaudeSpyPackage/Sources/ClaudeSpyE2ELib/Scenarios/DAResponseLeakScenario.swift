import Foundation

/// E2E scenario: Verify that SwiftTerm's Device Attributes (DA) and Device Status
/// Report (DSR) responses do not leak back into the tmux pane as typed input — on
/// both macOS and iOS.
///
/// When the terminal emulator (SwiftTerm) receives a DA query (`ESC[c`) or a DSR
/// query (e.g. `ESC[?6n`) in the data stream, it generates a response internally.
/// This response must be suppressed — if it's forwarded back (via local send-keys
/// on macOS, or via the relay WebSocket on iOS), it appears as garbage characters
/// typed into the shell prompt (e.g. `5;4;1;2;6;21;22;17;28c` from a DA leak or
/// `[?58;3;1R` from a DECXCPR leak).
///
/// Note: tmux's own terminal also responds to DA/DSR queries with its own response.
/// This is expected tmux behavior — the response goes via tmux's internal routing
/// directly to the inner program's stdin, not into pipe-pane output. The assertions
/// check specifically for SwiftTerm response fragments (`;28c`, `;22;17`, `?65;` for
/// DA; `;1R` for DECXCPR with page=1) which would only appear if SwiftTerm's response
/// leaked through.
///
/// This test:
/// 1. Pairs macOS and iOS, sets up a tmux pane mirrored on both
/// 2. Sends Primary DA queries (ESC[c) via printf and asserts no DA leak
/// 3. Sends DECXCPR queries (ESC[?6n) via printf and asserts no DSR leak
public enum DAResponseLeakScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "DA/DSR Response Leak",
        tags: ["rendering"]
    ) {
        // ── Phase 1: Pair macOS host with iOS simulator ───────────────
        FreshPairingScenario.scenario

        // ── Phase 2: Create tmux session ──────────────────────────────
        TestStep.log("Creating tmux session for DA response leak test")
        TestStep.tmuxCreateSession(name: "e2e-da-leak", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        // ── Phase 3: Open pane on macOS host ──────────────────────────
        Shortcut.openPanesWindow()
        TestStep.macResizeWindow(width: 900, height: 500)

        TestStep.macWaitForElement(titled: "e2e-da-leak", timeout: 10)
        TestStep.macClickButton(titled: "e2e-da-leak")
        TestStep.wait(seconds: 2)

        // Clear screen to have a clean baseline
        Shortcut.tmuxRunCommand(target: "e2e-da-leak:0", command: "clear")
        TestStep.wait(seconds: 1)

        // ── Phase 4: Test Primary DA with macOS only ──────────────────
        // At this point only the macOS SwiftTerm is mirroring the pane.
        TestStep.log("Sending Primary DA query (ESC[c) — macOS mirror active")
        Shortcut.tmuxRunCommand(
            target: "e2e-da-leak:0",
            command: #"printf '\e[c' && sleep 1 && echo MAC_DA1_DONE"#
        )
        TestStep.wait(seconds: 3)

        TestStep.tmuxCapturePaneContent(target: "e2e-da-leak:0", storeAs: "macDA1")
        // SwiftTerm DA response: ESC[?65;1;2;6;21;22;17;28c
        // These fragments are unique to SwiftTerm and won't match tmux's own
        // shorter DA response (ESC[?1;2;4c).
        TestStep.assertStoredNotContains(key: "macDA1", substring: ";28c")
        TestStep.assertStoredNotContains(key: "macDA1", substring: ";22;17")
        TestStep.assertStoredNotContains(key: "macDA1", substring: "?65;")

        // Verify the terminal UI also shows the completion marker
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("MAC_DA1_DONE")]),
            timeout: 10
        )

        TestStep.macScreenshot(label: "mac-after-da1", compare: false)

        // ── Phase 5: Open pane on iOS ─────────────────────────────────
        // Now the iOS SwiftTerm will also mirror the pane, adding a second
        // source of potential DA response leakage via the relay WebSocket.
        TestStep.log("Opening pane on iOS viewer")
        Shortcut.iosConnectToSession(sessionName: "e2e-da-leak")

        // Clear screen before the combined test
        Shortcut.tmuxRunCommand(target: "e2e-da-leak:0", command: "clear")
        TestStep.wait(seconds: 1)

        // ── Phase 6: Test Primary DA with both mirrors active ─────────
        // Both macOS and iOS SwiftTerm instances process the DA query.
        // If either leaks, we'll see response fragments in the pane.
        TestStep.log("Sending Primary DA query (ESC[c) — both mirrors active")
        Shortcut.tmuxRunCommand(
            target: "e2e-da-leak:0",
            command: #"printf '\e[c' && sleep 1 && echo BOTH_DA1_DONE"#
        )
        TestStep.wait(seconds: 3)

        TestStep.tmuxCapturePaneContent(target: "e2e-da-leak:0", storeAs: "bothDA1")
        TestStep.assertStoredNotContains(key: "bothDA1", substring: ";28c")
        TestStep.assertStoredNotContains(key: "bothDA1", substring: ";22;17")
        TestStep.assertStoredNotContains(key: "bothDA1", substring: "?65;")

        // Verify the terminal UI also shows the completion marker
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("BOTH_DA1_DONE")]),
            timeout: 10
        )

        TestStep.macScreenshot(label: "mac-both-after-da1", compare: false)
        TestStep.iosScreenshot(label: "ios-after-da1", compare: false)

        // ── Phase 7: Test DECXCPR query (ESC[?6n) with both mirrors active ─
        // SwiftTerm would respond with `ESC[?row;col;1R` (page is always 1).
        // If the response leaks via send-keys / relay, the literal characters
        // `[?…;1R` appear in the pane.
        Shortcut.tmuxRunCommand(target: "e2e-da-leak:0", command: "clear")
        TestStep.wait(seconds: 1)

        TestStep.log("Sending DECXCPR query (ESC[?6n) — both mirrors active")
        Shortcut.tmuxRunCommand(
            target: "e2e-da-leak:0",
            command: #"printf '\e[?6n' && sleep 1 && echo BOTH_DSR_DONE"#
        )
        TestStep.wait(seconds: 3)

        TestStep.tmuxCapturePaneContent(target: "e2e-da-leak:0", storeAs: "bothDSR")
        // SwiftTerm's DECXCPR response shape is `ESC[?row;col;1R`. The `;1R`
        // tail (page=1) is highly unusual in normal terminal output and only
        // appears here if SwiftTerm's response leaked through. We deliberately
        // do not assert on `[?` because the shell echoes the typed command line
        // (`printf '\e[?6n' …`) into the pane, which already contains `[?`.
        TestStep.assertStoredNotContains(key: "bothDSR", substring: ";1R")

        // Verify the terminal UI also shows the completion marker
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("BOTH_DSR_DONE")]),
            timeout: 10
        )

        TestStep.macScreenshot(label: "mac-both-after-dsr", compare: false)
        TestStep.iosScreenshot(label: "ios-after-dsr", compare: false)

        // ── Phase 8: Test DECRQM query (ESC[?2026$p) with both mirrors active ─
        // Mode 2026 = synchronized output. SwiftTerm would respond with
        // `ESC[?2026;2$y` (DECRPM). If the response leaks, the literal
        // `[?2026;2$y` appears in the pane.
        Shortcut.tmuxRunCommand(target: "e2e-da-leak:0", command: "clear")
        TestStep.wait(seconds: 1)

        TestStep.log("Sending DECRQM query (ESC[?2026$p) — both mirrors active")
        Shortcut.tmuxRunCommand(
            target: "e2e-da-leak:0",
            command: #"printf '\e[?2026$p' && sleep 1 && echo BOTH_DECRQM_DONE"#
        )
        TestStep.wait(seconds: 3)

        TestStep.tmuxCapturePaneContent(target: "e2e-da-leak:0", storeAs: "bothDECRQM")
        // SwiftTerm's DECRPM response for mode 2026 is `ESC[?2026;2$y` (status=2,
        // reset). The `;2$y` tail is unique to a leaked response — the typed
        // command line that the shell echoes contains `$p`, not `$y`, and `?2026`
        // alone is part of the typed query so we don't assert on it.
        TestStep.assertStoredNotContains(key: "bothDECRQM", substring: ";2$y")

        // Verify the terminal UI also shows the completion marker
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("BOTH_DECRQM_DONE")]),
            timeout: 10
        )

        TestStep.macScreenshot(label: "mac-both-after-decrqm", compare: false)
        TestStep.iosScreenshot(label: "ios-after-decrqm", compare: false)
    }
}
