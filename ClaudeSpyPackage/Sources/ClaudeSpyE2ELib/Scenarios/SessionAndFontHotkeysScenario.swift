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
/// The font phase runs with auto-resize enabled and asserts the *tmux-side*
/// pane dimensions shrink when the font grows (and return on restore): a
/// font-size change alters how many cells fit the same pixel area, so
/// auto-resize must re-fit the tmux pane or agents in it keep rendering at a
/// stale size. This pins the fix for font changes (hotkeys or the Settings
/// slider) not triggering auto-resize.
///
/// The font-demo session (`hkalpha`) is deliberately filled with many lines of
/// text so a font-size change moves a large fraction of the on-screen pixels.
/// That keeps the baseline comparison sensitive: if the ⌘+/⌘- hotkeys silently
/// stopped changing the font, the "increased" shot would look like the default
/// one and the comparison would fail loudly. A single line of output would only
/// nudge a handful of pixels and could slip under the comparison tolerance.
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
        // Fill hkalpha (the font-demo session) with many deterministic lines so a
        // font-size change repaints a large fraction of the pane — see the type
        // doc. Fixed line count + fixed text keeps the output stable across runs.
        Shortcut.tmuxRunCommand(
            target: "hkalpha:0",
            command: #"for i in $(seq 1 15); do echo "SESSION-ALPHA line $i: the quick brown fox jumps over"; done"#
        )

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
        // Auto-resize is enabled for the font phase: a font-size change
        // alters how many cells fit the same pixel area, so with auto-resize
        // on the app must resize the tmux pane too (bigger font → fewer
        // columns/rows) or agents in the pane keep rendering at a stale size.
        // The tmux-side dimensions are asserted below to pin that behavior.
        TestStep.log("Enable auto-resize on hkalpha for the font phase")
        TestStep.macClickButton(titled: "Auto-resize tmux pane when mirror view changes size")
        // Enabling the toggle performs an immediate resize to fit the mirror
        // view; let it land before recording the 12 pt reference dimensions.
        TestStep.wait(seconds: 1)
        TestStep.tmuxStorePaneDimensions(
            target: "hkalpha:0",
            widthKey: "fontDefaultWidth",
            heightKey: "fontDefaultHeight"
        )
        TestStep.log("Dimensions at default font: ${fontDefaultWidth}x${fontDefaultHeight}")
        // Status bar shows "WxH" — confirms the UI caught up with the resize.
        TestStep.macWaitForElement(titled: "${fontDefaultWidth}x${fontDefaultHeight}", timeout: 5)
        TestStep.macScreenshot(label: "mac-hotkeys-font-default")

        TestStep.log("Cmd-+ enlarges the terminal font (physically Cmd-Shift-=)")
        for _ in 0..<6 {
            TestStep.macPressKey(.character("="), modifiers: [.command, .shift])
        }
        // Cover the 200 ms auto-resize debounce plus the tmux round-trip.
        TestStep.wait(seconds: 1)
        TestStep.tmuxStorePaneDimensions(
            target: "hkalpha:0",
            widthKey: "fontIncreasedWidth",
            heightKey: "fontIncreasedHeight"
        )
        TestStep.log("Dimensions at increased font: ${fontIncreasedWidth}x${fontIncreasedHeight}")
        // The larger font must shrink the tmux pane in BOTH axes.
        TestStep.assertStoredNotEqual(key: "fontIncreasedWidth", otherKey: "fontDefaultWidth")
        TestStep.assertStoredNotEqual(key: "fontIncreasedHeight", otherKey: "fontDefaultHeight")
        TestStep.macWaitForElement(titled: "${fontIncreasedWidth}x${fontIncreasedHeight}", timeout: 5)
        TestStep.macScreenshot(label: "mac-hotkeys-font-increased")

        TestStep.log("Cmd-- shrinks the terminal font back to the default")
        for _ in 0..<6 {
            TestStep.macPressKey(.character("-"), modifiers: .command)
        }
        TestStep.wait(seconds: 1)
        TestStep.tmuxStorePaneDimensions(
            target: "hkalpha:0",
            widthKey: "fontRestoredWidth",
            heightKey: "fontRestoredHeight"
        )
        TestStep.log("Dimensions after restore: ${fontRestoredWidth}x${fontRestoredHeight}")
        // Symmetric restore → the pane returns to its 12 pt dimensions.
        TestStep.assertStoredEqual(key: "fontRestoredWidth", otherKey: "fontDefaultWidth")
        TestStep.assertStoredEqual(key: "fontRestoredHeight", otherKey: "fontDefaultHeight")
        TestStep.macScreenshot(label: "mac-hotkeys-font-restored")

        // ── Tear down ────────────────────────────────────────────────
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "hkalpha"])
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "hkbeta"])
        TestStep.wait(seconds: 2)
    }
}
