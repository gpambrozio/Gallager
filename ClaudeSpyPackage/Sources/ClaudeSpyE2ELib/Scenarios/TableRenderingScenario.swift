import Foundation

/// E2E scenario: Table / box-drawing character rendering
///
/// Verifies that DEC Special Graphics line-drawing characters render as
/// proper Unicode box-drawing glyphs in the mirror terminal. This
/// validates the fix for GitHub issue #186 where `capture-pane -e`
/// outputs SO (0x0E) / SI (0x0F) control characters around DEC
/// line-drawing chars, and `filterToColorCodesOnly` now translates them
/// to UTF-8 equivalents.
///
/// The scenario:
/// 1. Pairs macOS and iOS devices via the relay
/// 2. Creates a tmux session and writes the Python table-drawing script
/// 3. Selects the pane on macOS and navigates to it on iOS (both are
///    now streaming the terminal)
/// 4. Runs the script so both platforms see the table drawn via
///    live streaming data (exercises SO/SI translation in the stream)
/// 5. Takes screenshots on both platforms (streaming result)
/// 6. De-selects and re-selects the pane to force a re-capture, then
///    takes screenshots on both platforms to verify the table survives
///    a fresh capture-pane cycle
///
/// Box-drawing characters should render as: ┌─┬─┐ │ ├─┼─┤ └─┴─┘
/// NOT as ASCII: lqwqk x tqnqu mqvqj
public enum TableRenderingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Table Rendering",
        tags: ["rendering"]
    ) {
        // ── Pair devices ────────────────────────────────────────────
        // Pairing launches both apps and establishes the relay connection.

        FreshPairingScenario.scenario

        // ── Setup ─────────────────────────────────────────────────────

        TestStep.log("Creating tmux sessions for table rendering test")
        TestStep.tmuxCreateSession(name: "table-test", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "table-helper", width: 80, height: 24)

        // Use a plain prompt so it doesn't interfere with table rendering
        Shortcut.tmuxClearAndSetPrompt(target: "table-test:0")

        // ── Draw table using DEC line-drawing characters ──────────────
        //
        // This Python script uses ESC(0 / ESC(B to switch into and out of
        // the DEC Special Graphics charset. When tmux captures this pane
        // with `capture-pane -e`, it converts these to SO/SI (0x0E/0x0F)
        // sequences which our filterToColorCodesOnly must translate to
        // UTF-8 box-drawing characters.
        //
        // The script clears the screen and draws the table from the top,
        // so the screenshot only shows the table — no Python source code.
        // The table uses the full 80-column terminal width and includes
        // multi-line rows to stress-test rendering.

        // Write the table-drawing Python script to a temp file via the helper
        // pane, then run it from the test pane. This avoids command echo in
        // scrollback, making the screenshot deterministic.
        //
        // The script uses ESC(0 / ESC(B to switch DEC Special Graphics mode.
        // It draws a full-width (80-col) table with 3 columns and multi-line
        // rows, exercising all box-drawing junction types.
        TestStep.log("Writing table-drawing script to temp file")
        TestStep.tmuxSendKeys(
            target: "table-helper:0",
            keys: #"""
            cat > /tmp/draw_table.py << 'PYEOF'
            import sys
            E='\033'
            ON=E+'(0'    # Switch to DEC Special Graphics
            OFF=E+'(B'   # Switch back to ASCII
            C=E+'['      # CSI
            # DEC chars: l=┌ k=┐ m=└ j=┘ q=─ x=│ w=┬ v=┴ t=├ u=┤ n=┼
            # 3 columns: 24 + 26 + 24 = 74 content + 6 junctions/borders = 80
            W1=24; W2=26; W3=24
            def hline(left, mid, right):
                sys.stdout.write(ON+left+'q'*W1+mid+'q'*W2+mid+'q'*W3+right+OFF+'\n')
            def row(c1, c2, c3):
                sys.stdout.write(ON+'x'+OFF+c1.ljust(W1)+ON+'x'+OFF+c2.ljust(W2)+ON+'x'+OFF+c3.ljust(W3)+ON+'x'+OFF+'\n')
            sys.stdout.write(C+'2J'+C+'H')
            sys.stdout.write(C+'1;33m  Box-Drawing Table Rendering Test'+C+'0m\n\n')
            hline('l','w','k')
            row(' Name',' Description',' Status')
            hline('t','n','u')
            row(' Authentication',' User login and token',' Active')
            row('   Service',' management system','')
            hline('t','n','u')
            row(' Database Pool',' Connection pooling for',' Warning: 85%')
            row('   Manager',' PostgreSQL with auto-',' capacity')
            row('',' scaling and failover','')
            hline('t','n','u')
            row(' WebSocket Relay',' Real-time bidirectional',' Active')
            row('',' message routing between','')
            row('',' paired devices','')
            hline('t','n','u')
            row(' E2E Test Runner',' Automated scenario',' 32/33 passed')
            row('',' execution framework','')
            hline('m','v','j')
            sys.stdout.write('\n'+C+'1;32m  All services operational.'+C+'0m\n')
            sys.stdout.flush()
            PYEOF
            """#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "table-helper:0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // ── Select pane on macOS and iOS BEFORE running script ─────────
        // Both platforms will be streaming the terminal when the table
        // is drawn, exercising the live SO/SI → UTF-8 translation path.

        Shortcut.openPanesWindow()

        TestStep.macClickButton(titled: "table-test")
        TestStep.wait(seconds: 3)

        TestStep.log("Opening terminal pane on iOS mirror")
        Shortcut.iosConnectToSession(sessionName: "table-test")

        // ── Draw table while both platforms are streaming ────────────

        TestStep.log("Drawing table with DEC line-drawing characters")
        Shortcut.tmuxRunCommand(target: "table-test:0", command: "python3 /tmp/draw_table.py")
        TestStep.wait(seconds: 3)

        // Screenshot: table should show Unicode box-drawing characters
        // (┌─┬─┐ etc.) NOT ASCII (lqwqk etc.) — rendered via streaming
        TestStep.macScreenshot(label: "mac-table-streamed")
        TestStep.iosScreenshot(label: "ios-table-streamed")

        // ── Re-capture: de-select and re-select ───────────────────────
        // Forces a new capture-pane cycle to test the fresh capture path.

        TestStep.log("Forcing re-capture via pane re-selection")
        TestStep.macClickButton(titled: "table-helper")
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Sessions"))
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "table-test")
        TestStep.wait(seconds: 3)

        // Screenshot: table should still render correctly after re-capture
        TestStep.macScreenshot(label: "mac-table-after-recapture")

        TestStep.iosTap(.labelContains("table-test"))
        TestStep.wait(seconds: 3)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
        TestStep.wait(seconds: 3)
        TestStep.iosScreenshot(label: "ios-table-after-recapture")
    }
}
