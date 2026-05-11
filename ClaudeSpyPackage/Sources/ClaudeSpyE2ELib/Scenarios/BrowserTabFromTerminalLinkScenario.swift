import Foundation

/// E2E scenario: Verify the new in-app browser tab end-to-end.
///
/// **Issue:** #460 — A clicked http/https/ftp link in the terminal should open
/// in an in-app browser tab next to the file/terminal tabs, with the policy
/// driven by `settings.browserLinkBehavior` (Ask / Always in app / Always in
/// default browser) and a "remember my choice" toggle on the confirmation
/// sheet.
///
/// Two tmux sessions are created up front. In `weblinks` we render four
/// distinct OSC 8 hyperlinks. The second session (`other`) is the destination
/// for the "switch away and come back" leg, which proves the selected browser
/// tab survives a session switch and is re-selected when the user returns.
///
/// The hyperlink targets point at the orchestrator's relay server's `/health`
/// endpoint with different query strings so the browser tab's URL-based
/// de-duplication treats each click as a new tab while every page renders the
/// same deterministic `{"status":"ok"}` body.
///
/// Flow:
/// 1. Click link 1 with default `.ask` → confirmation sheet appears.
/// 2. Pick "In App" (no remember) → tab opens, setting stays `.ask`.
/// 3. Switch to `other` session and back → browser tab is still the active
///    detail view (its `WKWebView` is preserved on the per-session state).
/// 4. Click link 2 → sheet appears, toggle "Don't ask again", pick "In App"
///    → setting flips to `.alwaysInApp`.
/// 5. Open Settings → General and confirm the picker now reads
///    "Always in app".
/// 6. Click link 3 → opens directly, no sheet.
/// 7. Change the picker to "Always in default browser".
/// 8. Click link 4 → no new in-app browser tab is created (the click falls
///    through to `NSWorkspace`).
public enum BrowserTabFromTerminalLinkScenario {
    /// Window at (10, 10), size 1_200×700, sidebar 250. Title bar + tab bar
    /// take ~100 pt; SF Mono 12 cells are ~14 pt tall. Each `printf` produces
    /// two viewport rows (command echo + output), so the link rows after four
    /// sequential prints are 1, 3, 5, 7. `x = 400` lands inside the link text
    /// for every row (the visible label is padded so the click target is wide
    /// enough to absorb sub-pixel font drift).
    private static let linkClickX: Double = 400
    private static let link1Y: Double = 130
    private static let link2Y: Double = 158
    private static let link3Y: Double = 186
    private static let link4Y: Double = 214

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Browser Tab From Terminal Link",
        tags: ["browser", "terminal", "links", "macos-only"]
    ) {
        // The relay server gives us a deterministic HTTP endpoint
        // (`/health` → `{"status":"ok"}`) for the WKWebView to load, so the
        // page-content half of the browser-tab screenshots is reproducible.
        TestStep.startServer
        TestStep.verifyServerHealth

        // ── Two tmux sessions ────────────────────────────────────
        TestStep.log("Setup: Create two tmux sessions; populate weblinks with four OSC 8 hyperlinks")
        TestStep.tmuxCreateSession(name: "weblinks", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "weblinks:0")

        // Four OSC 8 hyperlinks to the relay server. Each URL is unique so the
        // browser-tab de-dup (`currentURL == url`) keeps a separate tab per
        // click. The visible label is wide enough that the fixed `x = 400`
        // click reliably hits the link span.
        let healthURL = "http://127.0.0.1:8765/health"
        Shortcut.tmuxRunCommand(
            target: "weblinks:0",
            command: #"printf '\e]8;;\#(healthURL)\aOPEN-LINK-1-EASY-CLICK-TARGET\e]8;;\a\n'"#
        )
        Shortcut.tmuxRunCommand(
            target: "weblinks:0",
            command: #"printf '\e]8;;\#(healthURL)?v=2\aOPEN-LINK-2-EASY-CLICK-TARGET\e]8;;\a\n'"#
        )
        Shortcut.tmuxRunCommand(
            target: "weblinks:0",
            command: #"printf '\e]8;;\#(healthURL)?v=3\aOPEN-LINK-3-EASY-CLICK-TARGET\e]8;;\a\n'"#
        )
        Shortcut.tmuxRunCommand(
            target: "weblinks:0",
            command: #"printf '\e]8;;\#(healthURL)?v=4\aOPEN-LINK-4-EASY-CLICK-TARGET\e]8;;\a\n'"#
        )
        TestStep.wait(seconds: 1)

        // Second session — its only role is to host the "switch away and
        // come back" leg in Phase 2.
        TestStep.tmuxCreateSession(name: "other", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "other:0")
        Shortcut.tmuxRunCommand(target: "other:0", command: "echo 'second session — switch target'")
        TestStep.wait(seconds: 1)

        // ── Launch app ────────────────────────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElement(titled: "weblinks", timeout: 5)
        TestStep.macClickButton(titled: "weblinks")
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-1")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-terminal-with-links")

        // ── Phase 1: .ask → confirmation sheet, pick "In App" ───
        TestStep.log("Phase 1: Click link 1 with default .ask → confirmation sheet")
        TestStep.macClickAtPoint(x: linkClickX, y: link1Y)
        TestStep.macWaitForElement(titled: "Open this link?", timeout: 5)
        TestStep.macScreenshot(label: "mac-confirmation-sheet")

        // Pick "In App" WITHOUT toggling "Don't ask again" — the setting must
        // stay at `.ask` so Phase 4 can still observe the prompt.
        TestStep.macClickButton(titled: "In App")
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 5)
        TestStep.macWaitForElementQuery(.labelContains("Browser tab:"), timeout: 5)
        // Let the page finish loading so the screenshot captures `{"status":"ok"}`.
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-first-browser-tab-opened")

        // ── Phase 2: Switch away and back — tab survives ─────────
        TestStep.log("Phase 2: Switch to the other session, come back, browser tab still selected")
        TestStep.macClickButton(titled: "other")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementToDisappear(titled: "Browser tab:", timeout: 5)
        TestStep.macScreenshot(label: "mac-other-session-no-browser-tab")

        TestStep.macClickButton(titled: "weblinks")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.labelContains("Browser tab:"), timeout: 5)
        // Let the page settle after the view tree rebuilds.
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-back-to-weblinks-browser-tab-still-selected")

        // ── Phase 3: "Don't ask again" flips setting to .alwaysInApp ─
        TestStep.log("Phase 3: Click link 2; toggle 'Don't ask again' + In App → setting flips to .alwaysInApp")
        // Switch back to the terminal window-tab so the link is clickable.
        TestStep.macClickButton(titled: "weblinks:0")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-2")]),
            timeout: 5
        )
        TestStep.macClickAtPoint(x: linkClickX, y: link2Y)
        TestStep.macWaitForElement(titled: "Open this link?", timeout: 5)
        TestStep.macClickButton(titled: "Don't ask again.")
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-confirmation-sheet-remember-on")
        TestStep.macClickButton(titled: "In App")
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 5)
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-second-browser-tab-opened")

        // ── Phase 4: Settings reflect the remembered choice ──────
        TestStep.log("Phase 4: Settings → General shows the picker, remembered as 'Always in app'")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macWaitForElement(titled: "When clicking web links in terminal", timeout: 5)
        // The Settings scene is fixed-size on this macOS build (AX resize is
        // rejected with kAXErrorCannotComplete) and the picker sits below the
        // visible area at default sizing. Scroll the form down so the picker
        // is on screen before capturing the baseline — the screenshot is only
        // useful as proof if the picker (and its current value) are visible.
        TestStep.macScrollWheel(deltaY: -5, count: 4)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-settings-always-in-app")
        TestStep.macCloseWindow(titled: "General")
        TestStep.wait(seconds: 1)

        // ── Phase 5: .alwaysInApp → click 3 opens directly ──────
        TestStep.log("Phase 5: With .alwaysInApp, clicking link 3 opens directly (no sheet)")
        TestStep.macClickButton(titled: "weblinks")
        TestStep.macClickButton(titled: "weblinks:0")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-3")]),
            timeout: 5
        )
        TestStep.macClickAtPoint(x: linkClickX, y: link3Y)
        // Confirmation sheet must NOT appear.
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 3)
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-third-browser-tab-direct-open")

        // ── Phase 6: Change picker to .alwaysInDefaultBrowser ───
        TestStep.log("Phase 6: Change setting to .alwaysInDefaultBrowser via the picker")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macWaitForElement(titled: "When clicking web links in terminal", timeout: 5)
        // Targeting the picker by its `.help(...)` exact string (rather than the
        // visible label "When clicking web links in terminal") narrows the
        // search to the popup button itself — the label text exists as a
        // separate non-actionable element that AXPress would otherwise reach
        // first, leaving the menu closed.
        TestStep.macClickMenuItem(
            menuButtonTitle: "How http/https/ftp links clicked in the terminal should open. " +
                "\"Ask\" shows a one-time dialog with a \"remember my choice\" toggle.",
            itemTitle: "Always in default browser"
        )
        TestStep.wait(seconds: 1)
        // Scroll Settings down so the screenshot captures the picker reading
        // its new value rather than the un-changed top of the General tab.
        TestStep.macScrollWheel(deltaY: -5, count: 4)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-settings-always-in-default-browser")
        TestStep.macCloseWindow(titled: "General")
        TestStep.wait(seconds: 1)

        // ── Phase 7: .alwaysInDefaultBrowser → no new in-app tab ─
        TestStep.log("Phase 7: With .alwaysInDefaultBrowser, clicking link 4 routes via URLOpener — no new in-app tab")
        TestStep.macClickButton(titled: "weblinks")
        TestStep.macClickButton(titled: "weblinks:0")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-4")]),
            timeout: 5
        )
        TestStep.macClickAtPoint(x: linkClickX, y: link4Y)
        // Neither the confirmation sheet nor a new in-app tab should appear.
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 3)
        TestStep.wait(seconds: 2)
        // The terminal must still be the selected view (we just clicked it),
        // proving no new browser tab grabbed the detail pane.
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-4")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-default-browser-no-new-tab")

        // The default-browser log is the in-app stand-in for `NSWorkspace.open`
        // during E2E. Phases 1, 3 and 5 all opened in-app browser tabs, so the
        // only entry should be link 4 — the click that ran after the picker
        // was flipped to `.alwaysInDefaultBrowser`. The `?v=2` and `?v=3`
        // not-contains catch a regression where the routing leaked an earlier
        // click to the default browser; link 1 has no query marker, so its
        // absence is covered by the visible browser-tab screenshots in
        // Phases 1/3/5 rather than a log assertion.
        TestStep.readFile(path: "${defaultBrowserLogPath}", storeAs: "defaultBrowserLog")
        TestStep.assertStoredContains(key: "defaultBrowserLog", substring: "\(healthURL)?v=4")
        TestStep.assertStoredNotContains(key: "defaultBrowserLog", substring: "\(healthURL)?v=2")
        TestStep.assertStoredNotContains(key: "defaultBrowserLog", substring: "\(healthURL)?v=3")

        // Tear down so we don't carry state into the next scenario.
        Shortcut.tmuxRunCommand(target: "weblinks:0", command: "exit")
        Shortcut.tmuxRunCommand(target: "other:0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
