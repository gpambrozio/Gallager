import Foundation

/// E2E scenario: the ⌘` / ⌘⇧` session-cycling and ⌘+ / ⌘- font-size hotkeys
/// added for issue #648.
///
/// Two local tmux sessions (`hkalpha`, `hkbeta`) are created. Because there are
/// exactly two, "next session" from one always lands on the other regardless of
/// the sidebar sort order, which keeps the assertions order-independent.
///
/// Selection is proven via the window-tab strip: only the *selected* session's
/// windows render there, and the active window tab carries an AX value of
/// "selected" (its label is `<session>:0 …`). So the mere appearance of a
/// `hkbeta:0` selected tab after ⌘` proves the session switched.
///
/// Font size is proven visually — the same session is screenshotted at the
/// default 12 pt, enlarged with six ⌘+ presses (to 18 pt, safely under the
/// 24 pt cap so it never clamps), then returned to 12 pt with six matching ⌘-
/// presses. The symmetric restore leaves the *persisted* font size untouched
/// so later scenarios' baselines are unaffected.
///
/// Note: `⌘+` is physically `⌘⇧=` (the `=`/`+` key), matching how the menu item
/// is bound and displayed; the driver's US key table gained `` ` `` (backtick,
/// key code 50) so this scenario can press it.
public enum SessionAndFontHotkeysScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Session And Font Hotkeys",
        tags: ["hotkeys", "session", "font", "macos-only"]
    ) {
        // ── Setup: two single-window local sessions ──────────────────
        // Stable `@gallager-description`s keep the sidebar labels (and thus the
        // screenshots) from falling back to the working-directory path, which
        // varies by checkout folder. A fixed prompt + a distinct marker per
        // session makes the two terminals visually different in the shots.
        TestStep.log("Setup: two tmux sessions hkalpha and hkbeta")
        TestStep.tmuxCreateSession(name: "hkalpha", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["set-option", "-t", "=hkalpha:", "@gallager-description", "Alpha"])
        Shortcut.tmuxClearAndSetPrompt(target: "hkalpha:0")
        Shortcut.tmuxRunCommand(target: "hkalpha:0", command: "echo SESSION-ALPHA")

        TestStep.tmuxCreateSession(name: "hkbeta", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["set-option", "-t", "=hkbeta:", "@gallager-description", "Beta"])
        Shortcut.tmuxClearAndSetPrompt(target: "hkbeta:0")
        Shortcut.tmuxRunCommand(target: "hkbeta:0", command: "echo SESSION-BETA")

        // ── Launch app ───────────────────────────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_300, height: 700)
        // Re-pin the sidebar after the resize so its width is deterministic
        // across runs (matches the tab-cycle scenarios).
        TestStep.macSetSidebarWidth(250)

        TestStep.macWaitForElement(titled: "hkalpha", timeout: 10)
        TestStep.macWaitForElement(titled: "hkbeta", timeout: 10)

        // ── Select hkalpha; its window tab is the selected one ────────
        TestStep.macClickButton(titled: "hkalpha")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("hkalpha:0"), .valueContains("selected")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-hotkeys-alpha-selected")

        // ── ⌘` cycles to the next session (hkbeta) ───────────────────
        TestStep.log("Cmd-` selects the next session — hkbeta")
        TestStep.macPressKey(.character("`"), modifiers: .command)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("hkbeta:0"), .valueContains("selected")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-hotkeys-next-session-beta")

        // ── ⌘` again wraps back to hkalpha ───────────────────────────
        TestStep.log("Cmd-` again wraps forward back to hkalpha")
        TestStep.macPressKey(.character("`"), modifiers: .command)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("hkalpha:0"), .valueContains("selected")]),
            timeout: 10
        )

        // ── ⌘⇧` steps to the previous session (hkbeta, wrapping) ──────
        TestStep.log("Cmd-Shift-` selects the previous session — hkbeta")
        TestStep.macPressKey(.character("`"), modifiers: [.command, .shift])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("hkbeta:0"), .valueContains("selected")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-hotkeys-prev-session-beta")

        // Return to hkalpha for the font-size demonstration.
        TestStep.macPressKey(.character("`"), modifiers: [.command, .shift])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("hkalpha:0"), .valueContains("selected")]),
            timeout: 10
        )

        // ── ⌘+ / ⌘- change the terminal font size ────────────────────
        TestStep.macScreenshot(label: "mac-hotkeys-font-default")

        TestStep.log("Cmd-+ enlarges the terminal font (physically Cmd-Shift-=)")
        for _ in 0..<6 {
            TestStep.macPressKey(.character("="), modifiers: [.command, .shift])
        }
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-hotkeys-font-increased")

        TestStep.log("Cmd-- shrinks the terminal font back to the default")
        for _ in 0..<6 {
            TestStep.macPressKey(.character("-"), modifiers: .command)
        }
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-hotkeys-font-restored")

        // ── Tear down ────────────────────────────────────────────────
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "hkalpha"])
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "hkbeta"])
        TestStep.wait(seconds: 2)
    }
}
