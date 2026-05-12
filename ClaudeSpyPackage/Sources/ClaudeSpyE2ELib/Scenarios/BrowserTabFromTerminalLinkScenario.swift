import Foundation

/// E2E scenario: Verify the in-app browser tab and per-domain browsing
/// preference end-to-end.
///
/// **Issues:** #460 (in-app browser + global policy) and #504 (per-domain
/// rules + dedicated "Browser" settings tab).
///
/// A clicked http/https/ftp link in the terminal opens according to the
/// effective behavior for the URL: a per-domain rule
/// (`settings.browserDomainRules`) takes precedence over the global
/// `settings.browserLinkBehavior` (Ask / Always in app / Always in default
/// browser). The confirmation dialog exposes two remember-my-choice toggles —
/// "Don't ask again." (global) and "Don't ask again for {host}." (per
/// domain) — that are mutually exclusive.
///
/// Two tmux sessions are created up front. In `weblinks` we render seven
/// distinct OSC 8 hyperlinks (links 1–4 drive the global-policy half;
/// links 5–7 drive the per-domain half). The second session (`other`) is the
/// destination for the "switch away and come back" leg, which proves the
/// selected browser tab survives a session switch and is re-selected when
/// the user returns.
///
/// The hyperlink targets all point at the orchestrator's relay server's
/// `/health` endpoint on `127.0.0.1` with different query strings so the
/// browser tab's URL-based de-duplication treats each click as a new tab
/// while every page renders the same deterministic `{"status":"ok"}` body.
/// Because every link shares the host `127.0.0.1`, a single per-domain rule
/// is sufficient to exercise the override.
///
/// Flow:
/// 1. Click link 1 with default `.ask` → confirmation sheet appears (now
///    showing both "Don't ask again." and "Don't ask again for 127.0.0.1:8765."
///    checkboxes).
/// 2. Pick "In App" (no remember) → tab opens, setting stays `.ask`.
/// 3. Switch to `other` session and back → browser tab is still the active
///    detail view (its `WKWebView` is preserved on the per-session state).
/// 4. Click link 2 → sheet appears, toggle global "Don't ask again", pick
///    "In App" → global flips to `.alwaysInApp`.
/// 5. Open Settings → Browser and confirm the picker now reads
///    "Always in app" (the picker lives in the new Browser tab, not General).
/// 6. Click link 3 → opens directly, no sheet.
/// 7. Change the picker to "Always in default browser".
/// 8. Click link 4 → no new in-app browser tab is created (the click falls
///    through to `URLOpener`).
/// 9. Reset the global picker back to "Ask" so the per-domain leg starts
///    from a clean state.
/// 10. Click link 5 → sheet appears, toggle "Don't ask again for 127.0.0.1:8765.",
///     pick "In App" → adds a per-domain rule (global stays `.ask`).
/// 11. Open Settings → Browser, confirm the rule appears in the list.
/// 12. Click link 6 → opens directly via the per-domain rule (no sheet, even
///     though the global is still `.ask`).
/// 13. Remove the per-domain rule from Settings → Browser.
/// 14. Click link 7 → sheet appears again (no rule, global `.ask`).
public enum BrowserTabFromTerminalLinkScenario {
    /// Window at (10, 10), size 1_200×700, sidebar 250. Title bar + tab bar
    /// take ~100 pt; SF Mono 12 cells are ~14 pt tall. Each `printf`
    /// produces two viewport rows (command echo + output), so the link
    /// rows after seven sequential prints are 1, 3, 5, 7, 9, 11, 13.
    /// `x = 400` lands inside the link text for every row (the visible
    /// label is padded so the click target is wide enough to absorb
    /// sub-pixel font drift).
    private static let linkClickX: Double = 400
    private static let link1Y: Double = 130
    private static let link2Y: Double = 158
    private static let link3Y: Double = 186
    private static let link4Y: Double = 214
    private static let link5Y: Double = 242
    private static let link6Y: Double = 270
    private static let link7Y: Double = 298

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
        TestStep.log("Setup: Create two tmux sessions; populate weblinks with seven OSC 8 hyperlinks")
        TestStep.tmuxCreateSession(name: "weblinks", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "weblinks:0")

        // Seven OSC 8 hyperlinks to the relay server. Each URL is unique so
        // the browser-tab de-dup (`currentURL == url`) keeps a separate tab
        // per click. The visible label is wide enough that the fixed
        // `x = 400` click reliably hits the link span. All links share the
        // host `127.0.0.1`, so a single per-domain rule applies to every
        // one of them — exactly what the Phase 10–14 leg needs.
        let healthURL = "http://127.0.0.1:8765/health"
        for index in 1...7 {
            let suffix = index == 1 ? "" : "?v=\(index)"
            Shortcut.tmuxRunCommand(
                target: "weblinks:0",
                command: #"printf '\e]8;;\#(healthURL)\#(suffix)\aOPEN-LINK-\#(index)-EASY-CLICK-TARGET\e]8;;\a\n'"#
            )
        }
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
        TestStep.log("Phase 4: Settings → Browser shows the picker, remembered as 'Always in app'")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Browser")
        TestStep.macWaitForWindow(titled: "Browser", timeout: 5)
        TestStep.macWaitForElement(titled: "When clicking web links in terminal", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-settings-always-in-app")
        TestStep.macCloseWindow(titled: "Browser")
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
        TestStep.macWaitForWindow(titled: "Browser", timeout: 5)
        TestStep.macWaitForElement(titled: "When clicking web links in terminal", timeout: 5)
        // Targeting the picker by its `.help(...)` exact string (rather than the
        // visible label "When clicking web links in terminal") narrows the
        // search to the popup button itself — the label text exists as a
        // separate non-actionable element that AXPress would otherwise reach
        // first, leaving the menu closed.
        TestStep.macClickMenuItem(
            menuButtonTitle: "How http/https/ftp links clicked in the terminal should open by default. " +
                "Domain-specific rules below override this for matching hosts.",
            itemTitle: "Always in default browser"
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-settings-always-in-default-browser")
        TestStep.macCloseWindow(titled: "Browser")
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

        // ── Phase 8: Reset global picker to "Ask" for the per-domain leg ──
        TestStep.log("Phase 8: Reset Settings → Browser global picker to 'Ask' so the per-domain leg starts clean")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "Browser", timeout: 5)
        TestStep.macClickMenuItem(
            menuButtonTitle: "How http/https/ftp links clicked in the terminal should open by default. " +
                "Domain-specific rules below override this for matching hosts.",
            itemTitle: "Ask"
        )
        TestStep.wait(seconds: 1)
        TestStep.macCloseWindow(titled: "Browser")
        TestStep.wait(seconds: 1)

        // Clear the default-browser log so Phase 14 assertions can verify no
        // new default-browser dispatches happened during the per-domain leg.
        TestStep.removeFile(path: "${defaultBrowserLogPath}")

        // ── Phase 9: Click link 5 → confirmation sheet appears again ─
        TestStep.log("Phase 9: With global .ask + no domain rule, clicking link 5 shows the sheet")
        TestStep.macClickButton(titled: "weblinks")
        TestStep.macClickButton(titled: "weblinks:0")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-5")]),
            timeout: 5
        )
        TestStep.macClickAtPoint(x: linkClickX, y: link5Y)
        TestStep.macWaitForElement(titled: "Open this link?", timeout: 5)

        // ── Phase 10: Add a per-domain rule via the dialog ───────
        TestStep.log("Phase 10: Toggle 'Don't ask again for 127.0.0.1:8765.' + In App → adds a per-domain rule")
        TestStep.macClickButton(titled: "Don't ask again for 127.0.0.1:8765.")
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-confirmation-sheet-domain-remember-on")
        TestStep.macClickButton(titled: "In App")
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 5)
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-fifth-browser-tab-via-domain-rule")

        // ── Phase 11: Settings → Browser lists the new rule ──────
        TestStep.log("Phase 11: Settings → Browser shows the per-domain rule for 127.0.0.1")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "Browser", timeout: 5)
        // Match the row-specific help text on the rule's remove button. The
        // bare "127.0.0.1" string would also match the terminal panes in the
        // background (the OSC 8 URLs contain that host), which would race the
        // settings UI building out.
        TestStep.macWaitForElement(titled: "Remove rule for 127.0.0.1:8765", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-settings-with-domain-rule")
        TestStep.macCloseWindow(titled: "Browser")
        TestStep.wait(seconds: 1)

        // ── Phase 12: Domain rule overrides global .ask for link 6 ─
        TestStep.log("Phase 12: Click link 6 → opens directly via the per-domain rule (no sheet)")
        TestStep.macClickButton(titled: "weblinks")
        TestStep.macClickButton(titled: "weblinks:0")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-6")]),
            timeout: 5
        )
        TestStep.macClickAtPoint(x: linkClickX, y: link6Y)
        // Confirmation sheet must NOT appear — the per-domain rule short-circuits .ask.
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 3)
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-sixth-browser-tab-via-domain-rule")

        // ── Phase 13: Remove the rule from Settings → Browser ────
        TestStep.log("Phase 13: Remove the per-domain rule from Settings → Browser")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "Browser", timeout: 5)
        TestStep.macClickButton(titled: "Remove rule for 127.0.0.1:8765")
        TestStep.wait(seconds: 0.5)
        // Same as Phase 11: assert the remove-button help text vanishes, not
        // the host string, since the terminal panes' AX value still includes
        // "127.0.0.1" from the rendered OSC 8 link text.
        TestStep.macWaitForElementToDisappear(titled: "Remove rule for 127.0.0.1:8765", timeout: 5)
        TestStep.macScreenshot(label: "mac-settings-after-removing-rule")
        TestStep.macCloseWindow(titled: "Browser")
        TestStep.wait(seconds: 1)

        // ── Phase 14: Rule removed → sheet reappears for link 7 ──
        TestStep.log("Phase 14: With the rule gone (global .ask), clicking link 7 shows the sheet again")
        TestStep.macClickButton(titled: "weblinks")
        TestStep.macClickButton(titled: "weblinks:0")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-7")]),
            timeout: 5
        )
        TestStep.macClickAtPoint(x: linkClickX, y: link7Y)
        TestStep.macWaitForElement(titled: "Open this link?", timeout: 5)
        TestStep.macScreenshot(label: "mac-confirmation-sheet-after-rule-removed")
        TestStep.macClickButton(titled: "Cancel")
        TestStep.wait(seconds: 1)

        // The per-domain leg used links 5 and 6 in-app and never picked
        // "In Default Browser", so the (re-initialised) default-browser log
        // must stay empty for those URLs.
        TestStep.readFile(path: "${defaultBrowserLogPath}", storeAs: "defaultBrowserLogPostDomain")
        TestStep.assertStoredNotContains(key: "defaultBrowserLogPostDomain", substring: "\(healthURL)?v=5")
        TestStep.assertStoredNotContains(key: "defaultBrowserLogPostDomain", substring: "\(healthURL)?v=6")

        // Tear down so we don't carry state into the next scenario.
        Shortcut.tmuxRunCommand(target: "weblinks:0", command: "exit")
        Shortcut.tmuxRunCommand(target: "other:0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
