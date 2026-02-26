import Foundation

/// E2E scenario: Verify terminal link detection on macOS and iOS
///
/// Tests both plain-text URL detection (via regex) and OSC 8 hyperlink escape
/// sequence detection. Verifies that links are visible (underlined) in mirrored
/// terminal sessions on both macOS and iOS.
///
/// **Setup:** Creates a tmux session, emits plain-text URLs and OSC 8 hyperlinks,
/// then verifies they render on both macOS (Panes window) and iOS (via pairing).
///
/// **OSC 8 format:** `\e]8;;URL\e\\LINK_TEXT\e]8;;\e\\`
/// The escape sequence attaches a hyperlink URL to the visible LINK_TEXT.
public enum TerminalLinksScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal Links",
        tags: ["terminal", "links"]
    ) {
        // ── Setup ─────────────────────────────────────────────────────

        TestStep.log("Creating tmux session for link testing")
        TestStep.tmuxCreateSession(name: "links-test", width: 120, height: 40)

        // Set a plain prompt to avoid shell color codes interfering with link rendering
        TestStep.tmuxSendKeys(
            target: "links-test:0.0",
            keys: #"export PS1='$ '"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "links-test:0.0", keys: "Enter")
        TestStep.tmuxSendKeys(target: "links-test:0.0", keys: "clear", literal: true)
        TestStep.tmuxSendKeys(target: "links-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.5)

        // ── Emit URLs ─────────────────────────────────────────────────

        // 1. Plain-text URL (detected by regex)
        TestStep.tmuxSendKeys(
            target: "links-test:0.0",
            keys: #"echo 'Plain URL: https://example.com/plain-link'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "links-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.3)

        // 2. OSC 8 hyperlink escape sequence
        // Format: \e]8;;URL\e\\VISIBLE_TEXT\e]8;;\e\\
        // Using \a (BEL) as string terminator since tmux handles it more reliably
        TestStep.tmuxSendKeys(
            target: "links-test:0.0",
            keys: #"printf 'OSC8 link: \e]8;;https://example.com/osc8-link\aClick Here\e]8;;\a\n'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "links-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.3)

        // 3. OSC 8 link where the visible text is also a URL (OSC 8 should take priority)
        TestStep.tmuxSendKeys(
            target: "links-test:0.0",
            keys: #"printf 'Dual link: \e]8;;https://example.com/real-target\ahttps://example.com/visible-url\e]8;;\a\n'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "links-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.5)

        // ── Verify on macOS ───────────────────────────────────────────

        TestStep.log("Verifying links on macOS")
        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(200)
        TestStep.wait(seconds: 1)

        // Select the links-test pane
        TestStep.macClickButton(titled: "links-test:0.0")
        TestStep.wait(seconds: 2)

        // Screenshot showing links rendered with underlines on macOS
        TestStep.macScreenshot(label: "mac-terminal-links", compare: false)

        // ── Verify on iOS ─────────────────────────────────────────────

        TestStep.log("Verifying links on iOS via pairing")
        TestStep.terminateMacApp()
        TestStep.wait(seconds: 1)

        // Use full pairing flow to connect iOS
        FreshPairingScenario.scenario

        // Create a new terminal session on iOS (which connects to tmux)
        TestStep.iosTap(.label("New Session"))
        TestStep.wait(seconds: 2)
        TestStep.iosWaitForElementToDisappear(.labelContains("Loading projects"), timeout: 15)
        TestStep.iosTap(.labelContains("New Terminal"))
        TestStep.wait(seconds: 2)
        TestStep.iosWaitForElement(.labelContains("Terminal"), timeout: 15)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting to terminal"), timeout: 15)
        TestStep.wait(seconds: 1)

        // Emit the same URLs in the active terminal via macOS (now paired)
        TestStep.tmuxSendKeys(target: "links-test:0.0", keys: "clear", literal: true)
        TestStep.tmuxSendKeys(target: "links-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.5)

        TestStep.tmuxSendKeys(
            target: "links-test:0.0",
            keys: #"echo 'Plain URL: https://example.com/plain-link'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "links-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.3)

        TestStep.tmuxSendKeys(
            target: "links-test:0.0",
            keys: #"printf 'OSC8 link: \e]8;;https://example.com/osc8-link\aClick Here\e]8;;\a\n'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "links-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 0.3)

        TestStep.tmuxSendKeys(
            target: "links-test:0.0",
            keys: #"printf 'Dual link: \e]8;;https://example.com/real-target\ahttps://example.com/visible-url\e]8;;\a\n'"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "links-test:0.0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // Screenshot showing links rendered with underlines on iOS
        TestStep.iosScreenshot(label: "ios-terminal-links", compare: false)
    }
}
