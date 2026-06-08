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
///
/// **Remote leg (Phases 15–22):** pair a second Mac as viewer (instance 1) and
/// re-exercise the same OSC 8 hyperlinks through the host's `weblinks` session
/// mirrored on the viewer. The remote click handler
/// (`MainView.handleRemoteTerminalURLClick`) routes through the **viewer's**
/// `browserLinkBehavior` — not the host's — so the viewer's setting (which
/// starts at `.ask` because each instance gets isolated in-memory preferences
/// under `--e2e-test`) is what drives the prompt and the in-app/system-browser
/// dispatch. In-app tabs land in the viewer's `remoteSessionTabsStates` tab
/// strip keyed by `"\(hostId):\(sessionName)"`.
///
/// 15. Pair a Mac viewer; open its Panes window at the same size as the host
///     so the existing link click coordinates apply.
/// 16. Viewer opens the `weblinks` remote session; click link 1 → viewer's
///     confirmation sheet appears (proves `onOpenURL` is now wired through
///     `RemoteTerminalContainerView`).
/// 17. Pick "In App" → an in-app browser tab opens in the viewer's remote tab
///     strip; switch to the `other` session on the viewer and back → the
///     remote browser tab survives the session switch (the
///     `remoteSessionTabsStates` cache holds the live `WKWebView`).
/// 18. Click link 2 → toggle "Don't ask again." + "In App" → the viewer's
///     global flips to `.alwaysInApp` independently of the host's.
/// 19. Click link 3 → opens directly (no sheet) on the viewer.
/// 20. Press Cmd-W with the remote browser tab focused → closes the tab and
///     returns focus to the originating tmux window (precedence rule mirrored
///     from the local Cmd-W path).
/// 21. Switch the viewer's picker to "Always in default browser" via its
///     Settings → Browser tab.
/// 22. Click link 4 → no in-app tab; the viewer's default-browser log records
///     `?v=4`, asserting the click routed through `URLOpener` on the viewer
///     side (not the host's).
public enum BrowserTabFromTerminalLinkScenario {
    /// Link clicks land inside a large multi-line OSC 8 block painted by
    /// `link_block.py` — a single hyperlink filling an 18×72 region of the pane —
    /// so a fixed `(x, y)` near the terminal's upper-middle reliably hits the
    /// link even as content shifts a row or two. (A one-row-tall target is
    /// fragile: the tab-bar height changing — e.g. the Git brand-mark icon grew
    /// the bar — or the Panes window auto-growing after session creation both
    /// move terminal rows enough to land a fixed click on the wrong line.) The
    /// script advances to the next URL on each keystroke (sent via
    /// `tmuxSendKeys`), so all seven links are driven from one long-lived
    /// process; the visible block contains only `OPEN-LINK-n` tokens (never the
    /// raw URL — that rides the non-printing OSC 8 escape), so a stray click can
    /// never scrape link text instead of opening the intended target.
    ///
    /// `(400, 200)` is a global-screen coordinate (window pinned at (10, 10),
    /// 1_200×700) comfortably inside the block.
    private static let linkClickX: Double = 400
    private static let linkClickY: Double = 200

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
        TestStep.log("Setup: Create two tmux sessions; render seven OSC 8 hyperlinks via link_block.py")
        TestStep.tmuxCreateSession(name: "weblinks", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "weblinks:0")

        // Seven OSC 8 hyperlinks to the relay server, driven by `link_block.py`:
        // it paints the current URL as a large multi-line block (a wide, drift-
        // tolerant click target) and advances to the next URL on each keystroke
        // (sent via `tmuxSendKeys`). Each URL is unique so the browser-tab de-dup
        // (`currentURL == url`) keeps a separate tab per click; all share host
        // `127.0.0.1` so one per-domain rule covers them (Phase 10–14). The URLs
        // are single-quoted so the shell doesn't glob the `?` in `?v=N`.
        let healthURL = "http://127.0.0.1:8765/health"
        let linkURLs = (1...7).map { "'\(healthURL)\($0 == 1 ? "" : "?v=\($0)")'" }.joined(separator: " ")
        TestStep.injectScript(name: "link_block.py")
        Shortcut.tmuxRunCommand(
            target: "weblinks:0",
            command: "python3 $TMPDIR/link_block.py \(linkURLs)"
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

        TestStep.macWaitForElement(titled: "weblinks", timeout: 5)
        TestStep.macClickButton(titled: "weblinks")
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-1")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-terminal-with-links")

        // ── Phase 1: .ask → confirmation sheet, pick "In App" ───
        TestStep.log("Phase 1: Click link 1 with default .ask → confirmation sheet")
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)
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
        TestStep.macWaitForElementToDisappear(titled: "Browser tab:", timeout: 5)
        TestStep.macScreenshot(label: "mac-other-session-no-browser-tab")

        TestStep.macClickButton(titled: "weblinks")
        TestStep.macWaitForElementQuery(.labelContains("Browser tab:"), timeout: 5)
        // Let the page settle after the view tree rebuilds.
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-back-to-weblinks-browser-tab-still-selected")

        // ── Phase 3: "Don't ask again" flips setting to .alwaysInApp ─
        TestStep.log("Phase 3: Click link 2; toggle 'Don't ask again' + In App → setting flips to .alwaysInApp")
        // Switch back to the terminal window-tab so the link is clickable.
        TestStep.macClickButton(titled: "weblinks:0")
        TestStep.tmuxSendKeys(target: "weblinks:0", keys: "Space") // advance link_block.py to link 2
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-2")]),
            timeout: 5
        )
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)
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
        TestStep.tmuxSendKeys(target: "weblinks:0", keys: "Space") // advance link_block.py to link 3
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-3")]),
            timeout: 5
        )
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)
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
        TestStep.tmuxSendKeys(target: "weblinks:0", keys: "Space") // advance link_block.py to link 4
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-4")]),
            timeout: 5
        )
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)
        // Neither the confirmation sheet nor a new in-app tab should appear.
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 3)
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
        TestStep.tmuxSendKeys(target: "weblinks:0", keys: "Space") // advance link_block.py to link 5
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-5")]),
            timeout: 5
        )
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)
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
        TestStep.tmuxSendKeys(target: "weblinks:0", keys: "Space") // advance link_block.py to link 6
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-6")]),
            timeout: 5
        )
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)
        // Confirmation sheet must NOT appear — the per-domain rule short-circuits .ask.
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 3)
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-sixth-browser-tab-via-domain-rule")

        // ── Phase 13: Remove the rule from Settings → Browser ────
        TestStep.log("Phase 13: Remove the per-domain rule from Settings → Browser")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "Browser", timeout: 5)
        TestStep.macClickButton(titled: "Remove rule for 127.0.0.1:8765")
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
        TestStep.tmuxSendKeys(target: "weblinks:0", keys: "Space") // advance link_block.py to link 7
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-7")]),
            timeout: 5
        )
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)
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

        // ── Phase 15: Pair a Mac viewer (instance 1) ─────────────
        // After Phase 14, Settings is closed and Cancel was just pressed in the
        // sheet, so the host's weblinks pane is the focused content. Re-open
        // Settings on the host and generate a viewer pairing code. The
        // last-visited tab persists across reopens, so Settings comes back up
        // on "Browser" — explicitly switch to "Remote Access" first. The
        // `Shortcut.addMacViewer` shortcut can't be used here because it
        // clicks an "Add Viewer" button that only appears once at least one
        // viewer is already paired; this scenario doesn't pair iOS first, so
        // the host's `RemoteAccessSettingsView.unpairedView` is showing and
        // the right entry point is "Generate Pairing Code".
        TestStep.log("Phase 15: Pair a Mac viewer to test remote terminal link routing on the viewer side")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "Browser", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.macWaitForWindow(titled: "Remote Access", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.wait(seconds: 3)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "viewerPairingCode")

        TestStep.launchMacApp(instance: 1)
        TestStep.wait(seconds: 3)

        TestStep.macOpenSettings(instance: 1)
        TestStep.macWaitForWindow(titled: "General", timeout: 5, instance: 1)
        TestStep.macSelectSettingsTab("Remote Hosts", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Add Host", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macFocusElement(titled: "Pairing Code", instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "${viewerPairingCode}", pressReturn: true, instance: 1)

        // Wait until both sides confirm connection before driving the UI; the
        // `Viewer connected` / `Host connected` labels are surfaced via
        // `RemoteAccessSettingsView` / `RemoteHostsSettingsView` once the
        // relay handshake finishes.
        TestStep.macWaitForElement(titled: "Viewer connected", timeout: 15)
        TestStep.macWaitForElement(titled: "Host connected", timeout: 15, instance: 1)

        // Close both Settings windows so the viewer's Panes window can take
        // focus for click-at-point steps later on.
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        TestStep.wait(seconds: 1)

        // Open the viewer's Panes window at the same size as the host so the
        // fixed-pixel link coordinates from the top of the file apply 1:1 to
        // the viewer's mirrored remote terminal. `openPanesWindow` resizes to
        // 1_000×600 by default; the override matches the host's 1_200×700.
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macResizeWindow(width: 1_200, height: 700, instance: 1)
        TestStep.wait(seconds: 1)

        // ── Phase 16: Click link 1 on viewer with default .ask → sheet ─
        // The viewer's `--e2e-test` storage starts each instance with a fresh
        // in-memory `PreferencesService`, so its `browserLinkBehavior` is the
        // default `.ask` regardless of what the host's setting is at this
        // point in the scenario. This is the critical test for the PR: the
        // `onOpenURL` callback wiring on `RemoteTerminalContainerView` must
        // route through `handleRemoteTerminalURLClick`, otherwise the click
        // would silently fall through to the system default browser.
        TestStep.log("Phase 16: Viewer opens weblinks remote session; click link 1 → viewer's confirmation sheet appears")
        TestStep.macWaitForElement(titled: "weblinks", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "weblinks", instance: 1)
        // Before advancing the host's link, settle on the host's *current* link
        // (7, where Phase 14 left it) and give the remote-terminal subscription a
        // beat to go live for incremental updates. The viewer can render the
        // current frame from its initial snapshot before it is registered to
        // receive subsequent repaints, so sending the advance keystroke too early
        // races the subscribe handshake — the 7→1 repaint streams before the
        // viewer is listening and the pane stays stuck on the prior link. This
        // "settle on the current link, then advance" guard is repeated before
        // every viewer-side link change (Phases 18/19/22).
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-7")]),
            timeout: 15,
            instance: 1
        )
        TestStep.wait(seconds: 2)
        // Cycle link_block.py (on the host) back to link 1 — it wraps from 7 —
        // and let the change mirror to the viewer over the now-live subscription.
        TestStep.tmuxSendKeys(target: "weblinks:0", keys: "Space")
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-1")]),
            timeout: 15,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-weblinks-remote-pane", instance: 1)

        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY, instance: 1)
        TestStep.macWaitForElement(titled: "Open this link?", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-confirmation-sheet", instance: 1)

        TestStep.macClickButton(titled: "In App", instance: 1)
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 5, instance: 1)
        TestStep.macWaitForElementQuery(.labelContains("Browser tab:"), timeout: 5, instance: 1)
        // Let the WKWebView finish loading so the screenshot captures
        // `{"status":"ok"}` rather than a blank pane.
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "viewer-first-remote-browser-tab", instance: 1)

        // ── Phase 17: Switch sessions on viewer + back → tab survives ─
        // The remote browser tab is parked on a `(hostId, sessionName)` entry
        // in `remoteSessionTabsStates`. Switching to a different remote
        // session (`other`) must hide it; coming back to `weblinks` must
        // re-expose the same live `WKWebView` instance.
        TestStep.log("Phase 17: Switch to `other` session and back; the remote browser tab survives")
        TestStep.macClickButton(titled: "other", instance: 1)
        TestStep.macWaitForElementToDisappear(titled: "Browser tab:", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-other-no-browser-tab", instance: 1)

        TestStep.macClickButton(titled: "weblinks", instance: 1)
        TestStep.macWaitForElementQuery(.labelContains("Browser tab:"), timeout: 5, instance: 1)
        // Let the view tree settle after the session-switch rebuild.
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "viewer-back-to-weblinks-browser-tab", instance: 1)

        // ── Phase 18: Toggle global "Don't ask again" on viewer ─
        // Switch back to the weblinks window-tab so the link row is clickable.
        // When a browser tab is selected the window tab is visually deselected
        // (per `RemoteWindowTabBar.windowTab` styling), but the same window
        // is still the underlying selection — clicking it just deselects the
        // browser tab and re-exposes the terminal.
        TestStep.log("Phase 18: Click link 2 on viewer; toggle 'Don't ask again' + In App → viewer's global flips to .alwaysInApp")
        TestStep.macClickButton(titled: "weblinks:0", instance: 1)
        // Settle on the current link (1) so the re-exposed terminal's subscription
        // is live before advancing — see the Phase 16 rationale.
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-1")]),
            timeout: 15,
            instance: 1
        )
        TestStep.wait(seconds: 2)
        TestStep.tmuxSendKeys(target: "weblinks:0", keys: "Space") // advance link_block.py to link 2
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-2")]),
            timeout: 15,
            instance: 1
        )
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY, instance: 1)
        TestStep.macWaitForElement(titled: "Open this link?", timeout: 5, instance: 1)
        TestStep.macClickButton(titled: "Don't ask again.", instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "In App", instance: 1)
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 5, instance: 1)
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "viewer-second-remote-browser-tab", instance: 1)

        // ── Phase 19: .alwaysInApp on viewer → link 3 opens directly ─
        TestStep.log("Phase 19: With viewer global .alwaysInApp, clicking link 3 opens directly")
        TestStep.macClickButton(titled: "weblinks:0", instance: 1)
        // Settle on the current link (2) before advancing — see the Phase 16 rationale.
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-2")]),
            timeout: 15,
            instance: 1
        )
        TestStep.wait(seconds: 2)
        TestStep.tmuxSendKeys(target: "weblinks:0", keys: "Space") // advance link_block.py to link 3
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-3")]),
            timeout: 15,
            instance: 1
        )
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY, instance: 1)
        // Confirmation sheet must NOT appear — `.alwaysInApp` short-circuits .ask.
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 3, instance: 1)
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "viewer-third-remote-browser-tab-direct", instance: 1)

        // ── Phase 20: Cmd-W closes the focused remote browser tab ─
        // With the third tab still selected, Cmd-W should close *that tab*
        // rather than the underlying remote tmux window — the precedence
        // rule added in `requestCloseSelectedWindow` for remote sessions.
        // After the close, focus returns to the originating tmux window
        // (`weblinks:0`) and the terminal contents re-appear in the detail
        // pane.
        TestStep.log("Phase 20: Cmd-W with remote browser tab focused → closes the tab, returns to terminal")
        TestStep.macPressKey(.character("w"), modifiers: .command, instance: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-3")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-after-cmd-w-browser-tab-closed", instance: 1)

        // ── Phase 21: Switch viewer picker to .alwaysInDefaultBrowser ─
        // The viewer's Settings was last on "Remote Hosts" during Phase 15
        // pairing, and SwiftUI re-opens the last-visited tab — so wait for
        // that title rather than "General" here.
        TestStep.log("Phase 21: Switch viewer's Settings → Browser picker to 'Always in default browser'")
        TestStep.macOpenSettings(instance: 1)
        TestStep.macWaitForWindow(titled: "Remote Hosts", timeout: 5, instance: 1)
        TestStep.macSelectSettingsTab("Browser", instance: 1)
        TestStep.macWaitForWindow(titled: "Browser", timeout: 5, instance: 1)
        TestStep.macWaitForElement(titled: "When clicking web links in terminal", timeout: 5, instance: 1)
        TestStep.macClickMenuItem(
            menuButtonTitle: "How http/https/ftp links clicked in the terminal should open by default. " +
                "Domain-specific rules below override this for matching hosts.",
            itemTitle: "Always in default browser",
            instance: 1
        )
        TestStep.wait(seconds: 1)
        TestStep.macCloseWindow(titled: "Browser", instance: 1)
        TestStep.wait(seconds: 1)

        // ── Phase 22: .alwaysInDefaultBrowser on viewer → link 4 routes via URLOpener ─
        // The viewer's `--default-browser-log` is wiped on launch (see
        // `ClaudeSpyServerApp` boot path), so it starts clean and `?v=4` is
        // the first and only entry expected to appear.
        TestStep.log("Phase 22: With viewer .alwaysInDefaultBrowser, link 4 routes via URLOpener; no in-app tab")
        TestStep.macClickButton(titled: "weblinks", instance: 1)
        TestStep.macClickButton(titled: "weblinks:0", instance: 1)
        // Settle on the current link (3) before advancing — see the Phase 16 rationale.
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-3")]),
            timeout: 15,
            instance: 1
        )
        TestStep.wait(seconds: 2)
        TestStep.tmuxSendKeys(target: "weblinks:0", keys: "Space") // advance link_block.py to link 4
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-4")]),
            timeout: 15,
            instance: 1
        )
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY, instance: 1)
        TestStep.macWaitForElementToDisappear(titled: "Open this link?", timeout: 3, instance: 1)
        // Terminal must still own the detail pane — proves no in-app browser
        // tab grabbed it.
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-4")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-default-browser-no-new-tab", instance: 1)

        // The viewer logs to its own per-instance default-browser file
        // (`defaultBrowserLogPath1`). Earlier Phase 16/18/19 clicks all
        // resolved in-app, so only `?v=4` should appear; the absence of v=1,
        // v=2 and v=3 is what guarantees that the in-app dispatches on the
        // viewer did not silently leak through to the system browser.
        TestStep.readFile(path: "${defaultBrowserLogPath1}", storeAs: "viewerDefaultBrowserLog")
        TestStep.assertStoredContains(key: "viewerDefaultBrowserLog", substring: "\(healthURL)?v=4")
        TestStep.assertStoredNotContains(key: "viewerDefaultBrowserLog", substring: healthURL + "\n")
        TestStep.assertStoredNotContains(key: "viewerDefaultBrowserLog", substring: "\(healthURL)?v=2")
        TestStep.assertStoredNotContains(key: "viewerDefaultBrowserLog", substring: "\(healthURL)?v=3")

        // Tear down so we don't carry state into the next scenario. `weblinks:0`
        // is running link_block.py (reading single keys), so send `q` to exit the
        // script back to the shell rather than a shell `exit` command.
        TestStep.tmuxSendKeys(target: "weblinks:0", keys: "q")
        Shortcut.tmuxRunCommand(target: "weblinks:0", command: "exit")
        Shortcut.tmuxRunCommand(target: "other:0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
