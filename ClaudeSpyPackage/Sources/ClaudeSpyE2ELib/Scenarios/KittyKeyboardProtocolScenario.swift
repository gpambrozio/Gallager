import Foundation

// swiftlint:disable function_body_length

/// E2E scenario: Verify that kitty keyboard protocol sequences are stripped from
/// the terminal data feed and do not corrupt the mirror display.
///
/// When Claude Code (2.1.78+) enables the kitty keyboard protocol via CSI sequences
/// like `ESC[>1u`, the mirror's SwiftTerm instance could enter an unsupported keyboard
/// mode. This caused:
/// - Garbage text (e.g., `5u`, `^[sent`) appearing in the mirrored output
/// - Arrow keys producing numbers instead of navigating
/// - Phantom escape key events
///
/// This test sends the same protocol negotiation sequences that Claude Code emits,
/// interleaved with known marker text, then captures the pane content and verifies
/// that no escape sequence fragments leaked through as visible text.
public enum KittyKeyboardProtocolScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Kitty Keyboard Protocol",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup ──────────────────────────────────────────────────────

        TestStep.tmuxCreateSession(name: "e2e-kitty-kb", width: 100, height: 30)

        Shortcut.macOnlySetup

        TestStep.macClickButton(titled: "e2e-kitty-kb")
        TestStep.wait(seconds: 2)

        // Clear screen for clean baseline
        Shortcut.tmuxRunCommand(target: "e2e-kitty-kb:0", command: "clear")
        TestStep.wait(seconds: 1)

        // ── Create inline test script ──────────────────────────────────
        //
        // This Python script emits the same kitty keyboard protocol sequences
        // that Claude Code sends, interleaved with marker text. If the mirror
        // fails to strip the protocol sequences, the markers will be corrupted
        // with leaked escape fragments (e.g., "^[sent" or "5usent").

        TestStep.log("Creating kitty keyboard protocol test script")
        TestStep.tmuxSendKeys(
            target: "e2e-kitty-kb:0",
            keys: #"""
            cat > $TMPDIR/kitty-kb-test.py << 'PYEOF'
            import sys,time
            def w(s):
                sys.stdout.buffer.write(s.encode() if isinstance(s,str) else s)
                sys.stdout.buffer.flush()

            # Phase 1: Individual protocol negotiation sequences
            # Each should be completely invisible to the mirror
            w("PHASE1_START\n")

            w("push1_before ")
            w("\x1b[>1u")       # Push mode: enable disambiguate-escape-codes
            time.sleep(0.1)
            w("push1_after\n")

            w("push5_before ")
            w("\x1b[>5u")       # Push mode: flags=5
            time.sleep(0.1)
            w("push5_after\n")

            w("query_before ")
            w("\x1b[?u")        # Query current mode
            time.sleep(0.1)
            w("query_after\n")

            w("setflags_before ")
            w("\x1b[=1;2u")     # Set specific flags
            time.sleep(0.1)
            w("setflags_after\n")

            w("pop_before ")
            w("\x1b[<u")        # Pop mode
            time.sleep(0.1)
            w("pop_after\n")

            w("\x1b[<u")        # Pop remaining
            time.sleep(0.1)

            w("PHASE1_DONE\n")

            # Phase 2: Interleaved with normal output (no gaps)
            w("PHASE2_START\n")
            w("before")
            w("\x1b[>1u")       # Should be stripped completely
            w("-after")
            w("\x1b[<u")        # Should be stripped completely
            w("-end\n")
            w("PHASE2_DONE\n")

            # Phase 3: Rapid push/pop cycling
            w("PHASE3_START\n")
            for i in range(10):
                w("\x1b[>1u")   # Push
                w(f"[{i}]")
                w("\x1b[<u")    # Pop
                time.sleep(0.02)
            w("\n")
            w("PHASE3_DONE\n")
            PYEOF
            """#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "e2e-kitty-kb:0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // ── Run the test script ────────────────────────────────────────

        // Clear the screen so heredoc prompt lines (which contain escape
        // sequence source code like "\x1b[>1u") don't pollute assertions.
        Shortcut.tmuxRunCommand(target: "e2e-kitty-kb:0", command: "clear")
        TestStep.wait(seconds: 1)

        TestStep.log("Running kitty keyboard protocol test script")
        Shortcut.tmuxRunCommand(target: "e2e-kitty-kb:0", command: "python3 $TMPDIR/kitty-kb-test.py")
        TestStep.wait(seconds: 3)

        // Screenshot right after script execution — shows the actual
        // mirror output, useful for debugging failures.
        TestStep.macScreenshot(label: "kitty-script-output")

        // ── Capture and assert ─────────────────────────────────────────

        TestStep.tmuxCapturePaneContent(target: "e2e-kitty-kb:0", storeAs: "kittyOutput")

        // Phase 1: Each marker pair should appear cleanly
        TestStep.assertStoredContains(key: "kittyOutput", substring: "PHASE1_DONE")
        TestStep.assertStoredContains(key: "kittyOutput", substring: "push1_before push1_after")
        TestStep.assertStoredContains(key: "kittyOutput", substring: "push5_before push5_after")
        TestStep.assertStoredContains(key: "kittyOutput", substring: "query_before query_after")
        TestStep.assertStoredContains(key: "kittyOutput", substring: "setflags_before setflags_after")
        TestStep.assertStoredContains(key: "kittyOutput", substring: "pop_before pop_after")

        // Phase 2: No gaps or leaked fragments between markers
        TestStep.assertStoredContains(key: "kittyOutput", substring: "before-after-end")

        // Phase 3: All 10 iterations present
        TestStep.assertStoredContains(key: "kittyOutput", substring: "[0][1][2][3][4][5][6][7][8][9]")

        // Negative assertions: none of these escape sequence fragments should appear
        // as visible text. These are the garbage patterns seen before the fix:
        // - "1u" from ESC[>1u leaking
        // - "5u" from ESC[>5u or ESC[=1;2u leaking
        // - "^[" from raw ESC bytes rendered as text
        TestStep.assertStoredNotContains(key: "kittyOutput", substring: "1u")
        TestStep.assertStoredNotContains(key: "kittyOutput", substring: "5u")
        TestStep.assertStoredNotContains(key: "kittyOutput", substring: "^[")

        TestStep.macScreenshot(label: "kitty-protocol-filtered")

        // ── Cleanup ────────────────────────────────────────────────────

        Shortcut.tmuxRunCommand(target: "e2e-kitty-kb:0", command: "rm $TMPDIR/kitty-kb-test.py")
    }
}

// swiftlint:enable function_body_length
