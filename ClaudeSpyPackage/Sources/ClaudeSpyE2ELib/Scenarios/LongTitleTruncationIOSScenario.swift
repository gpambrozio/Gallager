import Foundation

/// E2E scenario: Verify a very long session title truncates in the iOS
/// navigation bar instead of bleeding behind the back and toolbar buttons.
///
/// Regression test for #600. The session title is rendered as a `.principal`
/// toolbar item (a Menu whose label is the title plus a chevron) in
/// `WindowLayoutView`. Without a `maxWidth` constraint on the `HStack` label,
/// SwiftUI sized the `.principal` item to its full intrinsic width and drew
/// past the navigation bar's title region, behind the back button and the
/// trailing toolbar buttons. The screenshot baseline for
/// `ios-long-title-truncated` must show the title clipped with a trailing
/// ellipsis, contained between the back button and the trailing buttons.
///
/// 1. Pair macOS host with iOS simulator
/// 2. Create a tmux session on the host
/// 3. Set a very long title via OSC 2 escape sequence
/// 4. Verify the long title propagated to the host sidebar
/// 5. Open the pane on iOS and verify the title is truncated in the nav bar
public enum LongTitleTruncationIOSScenario {
    /// A title far too long to fit in the iOS navigation bar. Plain ASCII so it
    /// survives `printf` in the OSC escape sequence unchanged.
    private static let longTitle =
        "Truncation Test This Session Title Is Deliberately Far Too Long To Fit " +
        "In The iOS Navigation Bar And Must Be Clipped With A Trailing Ellipsis"

    /// A distinctive prefix that stays visible (and is present in the
    /// accessibility label regardless of visual truncation).
    private static let titlePrefix = "Truncation Test This Session Title"

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "iOS Long Title Truncation",
        tags: ["terminal-title", "ios"]
    ) {
        // 1. Pair macOS host with iOS simulator
        FreshPairingScenario.scenario

        // 2. Create a tmux session on the host
        TestStep.log("Creating tmux session on host")
        TestStep.tmuxCreateSession(name: "e2e-longtitle", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        // 3. Open the Panes window so the host discovers/streams the pane
        TestStep.log("Opening Panes window on host")
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "e2e-longtitle", timeout: 10)

        // 4. Set a very long terminal title via OSC 2 and verify it propagated
        TestStep.log("Setting a very long terminal title via OSC 2 escape sequence")
        Shortcut.tmuxRunCommand(
            target: "e2e-longtitle:0",
            command: "printf '\\033]2;\(longTitle)\\007'",
            literal: false
        )
        TestStep.macWaitForElementQuery(.labelContains(titlePrefix), timeout: 10)
        TestStep.macScreenshot(label: "host-long-title")

        // 5. Open the pane on iOS and verify the long title truncates in the nav bar
        TestStep.log("Connecting to the session on iOS")
        Shortcut.iosConnectToSession(sessionName: "e2e-longtitle")

        // The accessibility label keeps the full title even though the visible
        // text is truncated, so a substring match confirms the title is shown.
        TestStep.iosWaitForElement(.labelContains(titlePrefix), timeout: 15)
        // Settle wait — the terminal view's content rendering races with the
        // title bar update; without this the baseline is flaky.
        TestStep.wait(seconds: 1)
        // Baseline must show the title clipped with a trailing ellipsis, sitting
        // between the back button and the trailing toolbar buttons (not behind
        // them). This is the visual assertion for #600.
        TestStep.iosScreenshot(label: "ios-long-title-truncated")
    }
}
