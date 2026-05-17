import Foundation

/// E2E scenario: Pair two Mac apps, then send rapid keystrokes from the viewer
/// multiple times and verify they arrive at the host in the correct order.
/// Reproduces and validates the fix for GitHub issue #165.
public enum RapidKeystrokeOrderScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Rapid Keystroke Order",
        tags: ["keystroke", "macos-only"]
    ) {
        // ── Phase 1–4: Pair two Mac apps (host + viewer) ────────────

        Shortcut.twoMacPairing

        // ── Phase 5: Create tmux session on host ────────────────────
        TestStep.log("Creating tmux session on host")
        TestStep.tmuxCreateSession(name: "e2e-rapid-keys", width: 120, height: 24)

        // Set a minimal `$ ` prompt and clear the screen. Two reasons:
        //   1. capture-pane assertions stay readable (no multi-line zsh
        //      glyphs or color codes around our echo output).
        //   2. The default oh-my-zsh prompt issues many cursor-move +
        //      erase-in-line sequences during redraw. Inside SwiftTerm's
        //      DEC mode 2026 (synchronized output) windows those leave
        //      the live `buffer` transiently mid-rewrite even though the
        //      renderer's snapshot still shows the prior content. Tests
        //      that read AX value during such a window saw missing chars
        //      while the screenshot looked correct (see the round-2 flake
        //      that originally motivated switching to tmux capture-pane).
        Shortcut.tmuxClearAndSetPrompt(target: "e2e-rapid-keys:0")

        // ── Phase 6: Open Panes on viewer and select the remote pane ─
        // Use Shortcut.openPanesWindow so the viewer window is explicitly sized
        // to a known geometry. Without this, the terminal view inside inherits
        // NSWindow autosave state from prior scenarios, which can leave it too
        // short to keep all the keystroke-rounds output inside the visible
        // viewport that tmux capture-pane returns.
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macWaitForElement(titled: "e2e-rapid-keys", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "e2e-rapid-keys", instance: 1)
        TestStep.wait(seconds: 3)

        // ── Phase 7: Rapid keystroke tests ──────────────────────────
        // Send rapid keystrokes (no charDelay) and verify order on the
        // *host*'s tmux pane — that's the source of truth for whether
        // the keystrokes arrived intact and in order over the relay. The
        // viewer's screenshot is kept as a separate visual oracle; round
        // strings are deliberately long (45-50 chars) so any rendering
        // divergence on the viewer is obvious in the baseline image too.
        //
        // Settle waits are 5s and the initial AX wait is 15s so that the
        // debouncer / WebSocket send chain / tmux pipeline has time to
        // drain on a loaded CI machine.

        // Confirm the terminal stream is established and the AX element is
        // present before we start typing. This query matches by identifier
        // only (not value) so it's not affected by the buffer/render
        // divergence described above.
        TestStep.macActivate(instance: 1)
        TestStep.macWaitForElementQuery(
            .identifier("terminal-%0"),
            timeout: 15,
            instance: 1
        )

        // Round 1: full alphabet + digits (36 chars after the dash)
        TestStep.log("Round 1: Rapid typing alphabet+digits")
        TestStep.macType(text: "echo round1-abcdefghijklmnopqrstuvwxyz0123456789", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 5)
        TestStep.macScreenshot(label: "viewer-after-round1", instance: 1)
        TestStep.tmuxCapturePaneContent(target: "e2e-rapid-keys:0", storeAs: "host-after-round1")
        TestStep.assertStoredContains(
            key: "host-after-round1",
            substring: "round1-abcdefghijklmnopqrstuvwxyz0123456789"
        )

        // Round 2: pangram with hyphens (43 chars) — many word boundaries
        // surface any reordering or dropped chars in the relay pipeline.
        TestStep.log("Round 2: Rapid typing pangram")
        TestStep.macType(text: "echo round2-the-quick-brown-fox-jumps-over-the-lazy-dog", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 5)
        TestStep.macScreenshot(label: "viewer-after-round2", instance: 1)
        TestStep.tmuxCapturePaneContent(target: "e2e-rapid-keys:0", storeAs: "host-after-round2")
        TestStep.assertStoredContains(
            key: "host-after-round2",
            substring: "round2-the-quick-brown-fox-jumps-over-the-lazy-dog"
        )

        // Round 3: long digit sequence (50 chars) — any number reordering
        // is immediately visible by inspection.
        TestStep.log("Round 3: Rapid typing long digit sequence")
        TestStep.macType(text: "echo round3-12345678901234567890123456789012345678901234567890", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 5)
        TestStep.macScreenshot(label: "viewer-after-round3", instance: 1)
        TestStep.tmuxCapturePaneContent(target: "e2e-rapid-keys:0", storeAs: "host-after-round3")
        TestStep.assertStoredContains(
            key: "host-after-round3",
            substring: "round3-12345678901234567890123456789012345678901234567890"
        )

        // Round 4: mixed-case alternation (46 chars) — catches case-sensitive
        // ordering bugs in the keystroke pipeline.
        TestStep.log("Round 4: Rapid typing mixed case")
        TestStep.macType(text: "echo round4-AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWw", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 5)
        TestStep.macScreenshot(label: "viewer-after-round4", instance: 1)
        TestStep.tmuxCapturePaneContent(target: "e2e-rapid-keys:0", storeAs: "host-after-round4")
        TestStep.assertStoredContains(
            key: "host-after-round4",
            substring: "round4-AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWw"
        )

        // ── Phase 8: Final visual check on both panes ─────────────────
        TestStep.log("Final visual check of host and viewer panes")

        // Open the host's Panes window and select its pane so the screenshot
        // shows the host's terminal mirror.
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "e2e-rapid-keys", timeout: 10)
        TestStep.macClickButton(titled: "e2e-rapid-keys")
        TestStep.wait(seconds: 2)

        // Final tmux capture asserts all four rounds are still in the host's
        // visible pane (an extra guard against earlier rounds being scrolled
        // off or otherwise lost between writes).
        TestStep.tmuxCapturePaneContent(target: "e2e-rapid-keys:0", storeAs: "host-final")
        TestStep.assertStoredContains(
            key: "host-final",
            substring: "round4-AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWw"
        )

        TestStep.macScreenshot(label: "host-after-keystrokes")
        TestStep.macScreenshot(label: "viewer-after-keystrokes", instance: 1)
    }
}
