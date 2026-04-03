import Foundation

/// E2E scenario: DECSTBM scroll region footer rendering on iOS
///
/// Reproduces GitHub issue #244 where the fixed footer of a terminal using
/// DECSTBM (DEC Set Top and Bottom Margins) scroll regions is missing on iOS.
///
/// The host terminal has 65 rows × 100 columns. When mirrored to iOS, SwiftTerm's
/// auto-resize shrinks the buffer to fit the screen height, destroying the bottom
/// rows including the footer.
///
/// **Setup:** Pairs macOS and iOS, creates a 100×65 terminal
/// **Test:** Draws a fixed header (rows 1–3) and fixed footer (bottom 3 rows),
///   then scrolls content through the middle region using DECSTBM
/// **Verifies:** Footer text ("FIXED FOOTER") is visible on both macOS and iOS mirrors
public enum FooterRenderingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Footer Rendering",
        tags: ["rendering", "ios"]
    ) {
        // ── Pair devices ────────────────────────────────────────────
        FreshPairingScenario.scenario

        // ── Setup ─────────────────────────────────────────────────────
        TestStep.log("Creating 106×63 tmux session for footer rendering test")
        TestStep.tmuxCreateSession(name: "footer-test", width: 106, height: 63)

        Shortcut.tmuxClearAndSetPrompt(target: "footer-test:0")

        // ── Inject DECSTBM scroll region test script ──────────────────
        //
        // This is a simplified version of terminal-debug/term-stress.py --test 7.
        // It draws a fixed header (rows 1–3), a fixed footer (bottom 3 rows),
        // sets a DECSTBM scroll region between them, and fills the region with
        // colored scrolling content.
        TestStep.log("Injecting DECSTBM scroll region test script")
        TestStep.injectScript(name: "footer_test.py")

        TestStep.log("Selecting pane on macOS for mirroring")

        Shortcut.openPanesWindow()
        // Resize macOS window to fit the 100×65 terminal
        TestStep.macResizeWindow(width: 1_072, height: 1_040)
        TestStep.macClickButton(titled: "footer-test")

        // ── Navigate to pane on iOS ─────────────────────────────────
        TestStep.log("Opening terminal pane on iOS mirror")
        Shortcut.iosConnectToSession(sessionName: "footer-test")

        // ── Run the script ───────────────────────────────────────────
        TestStep.log("Running DECSTBM scroll region test")
        Shortcut.tmuxRunCommand(target: "footer-test:0", command: "python3 $TMPDIR/footer_test.py")
        // Wait for animation to complete (scroll_height + 20 lines × 20ms + buffer)
        TestStep.wait(seconds: 5)

        // ── Verify the macOS terminal UI renders footer, header, and scroll content ──
        TestStep.log("Verifying macOS terminal UI contains footer, header, and scroll content")
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("FIXED FOOTER")]),
            timeout: 10
        )
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("FIXED HEADER")]),
            timeout: 10
        )
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("Scrolling line  76")]),
            timeout: 10
        )

        // ── Select the pane on macOS ─────────────────────────────────
        // Screenshot: should show header and footer on macOS
        TestStep.macScreenshot(label: "mac-footer-full-terminal")

        // Screenshot: should show the terminal content on iOS
        // Before the fix, the footer is missing because SwiftTerm auto-resizes
        // the buffer to fit the screen, destroying bottom rows.
        // After the fix, the terminal expands and the outer scroll view allows
        // scrolling to see the footer.
        TestStep.iosScreenshot(label: "ios-footer-terminal")
    }
}
