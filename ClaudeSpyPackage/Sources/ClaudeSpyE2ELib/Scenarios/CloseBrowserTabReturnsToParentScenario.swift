import Foundation

/// E2E scenario: when a browser tab is opened from another browser tab
/// (`target="_blank"` / `window.open()`), closing the child must re-select
/// the parent tab — not bounce all the way back to the originating tmux
/// terminal. Verified for both a local session and a paired remote session
/// driven by a Mac viewer.
///
/// A tiny Python HTTP server (`popup_test_server.py`) runs on `127.0.0.1:9876`
/// and serves two deterministic pages — `/parent` (a huge centered link with
/// `target="_blank"`) and `/popup` ("POPUP PAGE"). Both pages have stable
/// `<title>` values so the tab strip's `.accessibilityLabel`
/// (`"Browser tab: <title>"`) is predictable for queries.
///
/// Flow (both legs):
/// 1. Click the OSC 8 terminal link → parent page opens in a browser tab.
/// 2. Click the link inside the parent page → popup spawns in a new tab
///    (selected) via the `WKUIDelegate.createWebViewWith` → `onNewTabRequest`
///    wiring. The new tab records the parent as its `parentTabId`.
/// 3. Close the popup tab → parent tab is re-selected (the regression this
///    scenario exists to catch — previously the originating terminal was
///    re-selected instead).
/// 4. Close the parent tab → originating terminal is re-selected (the
///    pre-existing `originWindowId` fallback still kicks in when no parent
///    is left).
public enum CloseBrowserTabReturnsToParentScenario {
    // Window: origin (10, 10), 1200×700, sidebar 250. The HTML page renders
    // a huge centered link, so a click at the geometric center of the
    // detail pane is guaranteed to hit it.
    private static let pageClickX: Double = 700
    private static let pageClickY: Double = 400

    // First-row OSC 8 link y-coordinate, matching the math used by
    // `BrowserTabFromTerminalLinkScenario`: window chrome takes ~100pt;
    // line 0 of the terminal lands at y ≈ 130.
    private static let terminalLinkX: Double = 400
    private static let terminalLinkY: Double = 130

    // Help text on the Settings → Browser default-behavior picker. Copy of
    // the string used by `BrowserTabFromTerminalLinkScenario` so any future
    // edit to the picker's help moves both scenarios together.
    private static let browserBehaviorPickerHelp =
        "How http/https/ftp links clicked in the terminal should open by default. " +
        "Domain-specific rules below override this for matching hosts."

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Close Browser Tab Returns To Parent",
        tags: ["browser", "popup", "links"]
    ) {
        // The relay server is needed for the remote leg in Phase 5+.
        TestStep.startServer
        TestStep.verifyServerHealth

        // ── Setup: Python server + tmux + OSC 8 link ──────────────
        TestStep.log("Setup: start popup_test_server.py in a side tmux window and print OSC 8 link in window 0")
        TestStep.injectScript(name: "popup_test_server.py")

        TestStep.tmuxCreateSession(name: "popups", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "popups:0")

        // Run the Python server in a separate tmux window so its access
        // logs (silenced anyway) don't pollute the visible click-target
        // pane. The window is addressable by name ("server") and by index 1.
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "popups", "-n", "server"])
        Shortcut.tmuxRunCommand(
            target: "popups:server",
            command: "python3 $TMPDIR/popup_test_server.py"
        )
        // Confirm the server printed READY before we drive any clicks.
        TestStep.wait(seconds: 2)
        TestStep.tmuxCapturePaneContent(target: "popups:server", storeAs: "serverLog")
        TestStep.assertStoredContains(key: "serverLog", substring: "READY 9876")

        // Switch back to window 0 and print the OSC 8 link. The visible
        // label is wide enough that the fixed-pixel `terminalLinkX` click
        // reliably hits the link span.
        TestStep.tmuxCommand(arguments: ["select-window", "-t", "popups:0"])
        Shortcut.tmuxRunCommand(
            target: "popups:0",
            command: #"printf '\e]8;;http://127.0.0.1:9876/parent\aOPEN-PARENT-PAGE-EASY-CLICK-TARGET\e]8;;\a\n'"#
        )
        TestStep.wait(seconds: 1)

        // ── Launch app + size window ──────────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        // Flip the global browser picker to "Always in app" so the OSC 8
        // click in Phase 1 skips the confirmation sheet. This scenario
        // exercises the popup-close behaviour, not the prompt; the prompt
        // is already covered by `BrowserTabFromTerminalLinkScenario`.
        TestStep.log("Setup: Settings → Browser → 'Always in app' so the OSC 8 click skips the prompt")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Browser")
        TestStep.macWaitForWindow(titled: "Browser", timeout: 5)
        TestStep.macClickMenuItem(
            menuButtonTitle: browserBehaviorPickerHelp,
            itemTitle: "Always in app"
        )
        TestStep.wait(seconds: 1)
        TestStep.macCloseWindow(titled: "Browser")

        TestStep.macWaitForElement(titled: "popups", timeout: 5)
        TestStep.macClickButton(titled: "popups")
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-PARENT-PAGE")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-terminal-with-osc-link")

        // ── Local Phase 1: terminal link → parent tab ─────────────
        TestStep.log("Local 1: Click OSC 8 link → parent page opens in browser tab")
        TestStep.macClickAtPoint(x: terminalLinkX, y: terminalLinkY)
        TestStep.macWaitForElementQuery(.labelContains("Browser tab: Parent"), timeout: 10)
        // Let WKWebView finish painting so the centered link target is in
        // place before Phase 2 clicks it.
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-parent-tab-opened")

        // ── Local Phase 2: target=_blank → popup tab ──────────────
        TestStep.log("Local 2: Click target=_blank link inside parent → popup spawns and becomes selected")
        TestStep.macClickAtPoint(x: pageClickX, y: pageClickY)
        TestStep.macWaitForElementQuery(.labelContains("Browser tab: Popup"), timeout: 10)
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-popup-tab-selected")

        // ── Local Phase 3: close popup → parent re-selected ───────
        TestStep.log("Local 3: Close popup → parent is re-selected (the new behavior under test)")
        TestStep.macClickButton(titled: "Close browser tab: Popup")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("Browser tab: Parent"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("Browser tab: Popup"),
            timeout: 5
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-after-close-popup-parent-selected")

        // ── Local Phase 4: close parent → terminal re-selected ────
        TestStep.log("Local 4: Close parent → originating terminal re-selected (legacy originWindowId fallback)")
        TestStep.macClickButton(titled: "Close browser tab: Parent")
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("Browser tab:"),
            timeout: 5
        )
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-PARENT-PAGE")]),
            timeout: 5
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-after-close-parent-terminal-back")

        // ── Phase 5: pair a Mac viewer for the remote leg ─────────
        // Pairing flow inlined (rather than `Shortcut.addMacViewer`) because
        // that shortcut expects a prior iOS pairing; this scenario doesn't
        // pair iOS, so the host shows the "unpaired" view and the right
        // entry point is "Generate Pairing Code".
        TestStep.log("Phase 5: Pair a Mac viewer to exercise the same close-popup-return on the viewer side")
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

        TestStep.macWaitForElement(titled: "Viewer connected", timeout: 15)
        TestStep.macWaitForElement(titled: "Host connected", timeout: 15, instance: 1)

        // Flip the viewer's browser picker to "Always in app" so the remote
        // OSC 8 click is also direct. The viewer's `--e2e-test` storage is
        // an isolated in-memory `PreferencesService` per instance, so the
        // host's setting doesn't carry over.
        TestStep.macSelectSettingsTab("Browser", instance: 1)
        TestStep.macWaitForWindow(titled: "Browser", timeout: 5, instance: 1)
        TestStep.macClickMenuItem(
            menuButtonTitle: browserBehaviorPickerHelp,
            itemTitle: "Always in app",
            instance: 1
        )
        TestStep.wait(seconds: 1)
        TestStep.macCloseWindow(titled: "Browser", instance: 1)
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.wait(seconds: 1)

        // Open the viewer's Panes window at the same size as the host so
        // the fixed-pixel link coordinates apply 1:1.
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macResizeWindow(width: 1_200, height: 700, instance: 1)

        // The OSC 8 link printed earlier in `popups:0` is still in the
        // pane (terminal scrollback persists), so the viewer's mirror of
        // the same pane shows it without re-printing.
        TestStep.macWaitForElement(titled: "popups", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "popups", instance: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-PARENT-PAGE")]),
            timeout: 15,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-popups-remote-pane", instance: 1)

        // ── Remote Phase 6: terminal link → parent tab ────────────
        TestStep.log("Remote 6: Viewer clicks OSC 8 link → parent page opens in remote browser tab")
        TestStep.macClickAtPoint(x: terminalLinkX, y: terminalLinkY, instance: 1)
        TestStep.macWaitForElementQuery(.labelContains("Browser tab: Parent"), timeout: 10, instance: 1)
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "viewer-parent-tab-opened", instance: 1)

        // ── Remote Phase 7: target=_blank → popup tab ─────────────
        TestStep.log("Remote 7: Viewer clicks target=_blank link in parent → popup tab spawns")
        TestStep.macClickAtPoint(x: pageClickX, y: pageClickY, instance: 1)
        TestStep.macWaitForElementQuery(.labelContains("Browser tab: Popup"), timeout: 10, instance: 1)
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "viewer-popup-tab-selected", instance: 1)

        // ── Remote Phase 8: close popup → parent re-selected ──────
        TestStep.log("Remote 8: Close popup on viewer → parent is re-selected (NOT terminal)")
        TestStep.macClickButton(titled: "Close browser tab: Popup", instance: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("Browser tab: Parent"), .valueContains("selected")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("Browser tab: Popup"),
            timeout: 5,
            instance: 1
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "viewer-after-close-popup-parent-selected", instance: 1)

        // Teardown: stop the Python server, then exit the shells. The
        // orchestrator kills the tmux server anyway, but this leaves a
        // clean exit trail in case anything inspects the pane on failure.
        TestStep.tmuxSendKeys(target: "popups:server", keys: "C-c")
        TestStep.wait(seconds: 0.5)
        Shortcut.tmuxRunCommand(target: "popups:server", command: "exit")
        Shortcut.tmuxRunCommand(target: "popups:0", command: "exit")
        TestStep.wait(seconds: 1)
    }
}
