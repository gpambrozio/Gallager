import Foundation

/// E2E scenario: Emoji table rendering regression test
///
/// Verifies that tables containing emoji characters render correctly in
/// both macOS and iOS mirror terminals. This catches regressions in:
/// - Emoji display width (2-column characters)
/// - Box-drawing character alignment alongside emoji
/// - Table border integrity when emoji are present
/// - Color/SGR state after wide characters
///
/// The scenario:
/// 1. Pairs macOS and iOS devices via the relay
/// 2. Creates a tmux session (80×35) and writes the Python table script
/// 3. Selects the pane on macOS and navigates to it on iOS (both are
///    now streaming the terminal)
/// 4. Runs the script so both platforms see the tables drawn via
///    live streaming data
/// 5. Takes screenshots on both macOS and iOS (streaming result)
/// 6. Forces a re-capture and takes final screenshots to verify
///    capture-pane correctly preserves emoji positioning
public enum EmojiTableRenderingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Emoji Table Rendering",
        tags: ["rendering"]
    ) {
        // -- Pair devices --------------------------------------------------

        FreshPairingScenario.scenario

        // -- Setup ---------------------------------------------------------

        TestStep.log("Creating tmux sessions for emoji table rendering test")
        TestStep.tmuxCreateSession(name: "emoji-tbl", width: 80, height: 35)
        TestStep.tmuxCreateSession(name: "emoji-helper", width: 80, height: 24)

        // -- Copy the Python script that draws all three tables ----------
        //
        // Uses UTF-8 box-drawing characters directly (not DEC line-drawing)
        // so we test the emoji rendering path specifically, not the SO/SI
        // translation tested by TableRenderingScenario.

        TestStep.log("Injecting emoji table rendering script")
        TestStep.injectScript(name: "emoji_tables.py")

        // -- Select pane on macOS and iOS BEFORE clear/prompt setup ----
        // Both platforms must be streaming when we run the prompt + clear
        // commands, so the mirror's SwiftTerm sees them directly and
        // pre-clear shell history doesn't end up in the scrollback that
        // capture-pane would later replay on re-selection.

        Shortcut.openPanesWindow()
        TestStep.macResizeWindow(width: 1_100, height: 700)

        TestStep.macClickButton(titled: "emoji-tbl")
        TestStep.wait(seconds: 3)

        TestStep.log("Opening terminal pane on iOS mirror")
        Shortcut.iosConnectToSession(sessionName: "emoji-tbl")

        // Plain prompt + clear, run while both platforms are streaming.
        Shortcut.tmuxRunCommand(target: "emoji-tbl:0", command: #"export PS1='$ '"#)
        TestStep.wait(seconds: 0.5)
        Shortcut.tmuxRunCommand(target: "emoji-tbl:0", command: "clear")
        TestStep.wait(seconds: 1)

        // -- Run script while both platforms are streaming ----------------

        TestStep.log("Running emoji table script")
        Shortcut.tmuxRunCommand(target: "emoji-tbl:0", command: "python3 $TMPDIR/emoji_tables.py")
        TestStep.wait(seconds: 3)

        // Screenshot: all three emoji tables rendered via streaming
        TestStep.macScreenshot(label: "mac-emoji-tables-streamed")
        TestStep.iosScreenshot(label: "ios-emoji-tables-streamed")

        // -- Re-capture: de-select and re-select ---------------------------
        // Forces a new capture-pane cycle to verify that extractActiveSGR
        // and filterToColorCodesOnly correctly handle wide characters
        // during re-capture (fresh capture path).

        TestStep.log("Forcing re-capture via pane re-selection")
        TestStep.macClickButton(titled: "emoji-helper")
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Sessions"))
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "emoji-tbl")
        TestStep.wait(seconds: 3)

        // Screenshot: tables should still render correctly after re-capture
        TestStep.macScreenshot(label: "mac-emoji-tables-recapture")

        TestStep.iosTap(.labelContains("emoji-tbl"))
        TestStep.wait(seconds: 3)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
        TestStep.wait(seconds: 3)
        TestStep.iosScreenshot(label: "ios-emoji-tables-recapture")
    }
}
