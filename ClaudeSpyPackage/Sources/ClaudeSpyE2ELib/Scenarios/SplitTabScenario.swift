import Foundation

/// E2E scenario: Verify the split-view feature for file and browser tabs.
///
/// **Issue:** #498 — The detail content area can be split into two panes so
/// the user can look at two tabs side by side. Each file/browser tab gets an
/// icon next to its close button — a split icon while the layout is
/// single-pane, and a side-arrow icon while the layout is split. The arrow
/// points to the side the tab will move to when clicked. When the right pane
/// becomes empty the layout collapses back to single-pane and split icons
/// reappear on every tab.
///
/// Two global Behavior settings round out the feature:
/// - "Always open files in split tab" — when on, opening any new file tab
///   sends it to the right pane (creating one if needed).
/// - "Always open links in split tab" — same idea for browser tabs.
///
/// This scenario covers:
/// - Splitting a view by clicking the split icon on a file tab.
/// - Moving tabs back and forth between sides via the arrow icons.
/// - Collapsing the split by moving the last right-side tab back to the left.
/// - Collapsing the split by closing the last right-side tab.
/// - Persistence of split state across a tmux session switch.
/// - The "Always open links in split tab" setting routing a new browser tab
///   directly to the right pane on the next terminal-link click.
public enum SplitTabScenario {
    /// Screen coordinates of the visible hyperlink text. Computed for window
    /// position (10, 10), size 1_200×700, sidebar width 250 — same formula as
    /// `TerminalFileLinkScenario` and `BrowserTabFromTerminalLinkScenario`.
    private static let linkClickX: Double = 400
    private static let linkClickY: Double = 130

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Split Tab View",
        tags: ["file-browser", "browser", "split-view", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        // The relay server is needed for Phase 6's in-app browser tab — the
        // health endpoint gives the WKWebView a deterministic page to load.
        TestStep.startServer
        TestStep.verifyServerHealth

        TestStep.log("Setup: Create two tmux sessions for the persistence phase")
        TestStep.tmuxCreateSession(name: "split", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "split:0")
        // OSC 8 hyperlink so Phase 6 can click an http link and exercise the
        // alwaysOpenLinksInSplit setting through the real terminal pipeline.
        let healthURL = "http://127.0.0.1:8765/health"
        Shortcut.tmuxRunCommand(
            target: "split:0",
            command: #"printf '\e]8;;\#(healthURL)\aOPEN-LINK-EASY-CLICK-TARGET\e]8;;\a\n'"#
        )
        TestStep.wait(seconds: 1)

        TestStep.tmuxCreateSession(name: "other", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "other:0")
        Shortcut.tmuxRunCommand(target: "other:0", command: "echo 'second session for round trip'")
        TestStep.wait(seconds: 1)

        // ── Launch app ───────────────────────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElement(titled: "split", timeout: 5)
        TestStep.macClickButton(titled: "split")
        TestStep.wait(seconds: 2)

        // ── Phase 1: Open two file tabs in the single-pane layout ──
        TestStep.log("Phase 1: Open hello.txt and README.md as file tabs")
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "README.md", timeout: 10)

        TestStep.macContextMenuClick(elementTitle: "hello.txt", menuItem: "Open in New Tab")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)

        // Switch back to the tree so the second file's right-click hits the row
        // and not the open-tab label.
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)
        TestStep.macContextMenuClick(elementTitle: "README.md", menuItem: "Open in New Tab")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "File tab: README.md", timeout: 5)

        // Select hello.txt so the icon next to its close button is visible
        // (icons are gated on hover/selected to match the close X behaviour).
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-split-two-tabs-no-split")

        // ── Phase 2: Click the split icon on hello.txt → split opens ──
        TestStep.log("Phase 2: Click split icon on hello.txt; layout splits and the tab moves to the right")
        TestStep.macClickButton(titled: "Open file tab in split: hello.txt")
        TestStep.wait(seconds: 2)

        // The split divider should now be on screen and the right pane should
        // exist. The arrow icons replace the split icons on every file tab.
        TestStep.macWaitForElement(titled: "Move file tab to left: hello.txt", timeout: 5)
        TestStep.macWaitForElement(titled: "Move file tab to right: README.md", timeout: 5)
        TestStep.macScreenshot(label: "mac-split-active-hello-on-right")

        // ── Phase 3: Send README.md to the right too ────────────────
        TestStep.log("Phase 3: Send README.md to the right pane")
        TestStep.macClickButton(titled: "File tab: README.md")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Move file tab to right: README.md")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "Move file tab to left: README.md", timeout: 5)
        TestStep.macScreenshot(label: "mac-split-both-on-right")

        // ── Phase 4: Move hello.txt back to the left ────────────────
        TestStep.log("Phase 4: Send hello.txt back to the left side")
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Move file tab to left: hello.txt")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "Move file tab to right: hello.txt", timeout: 5)
        TestStep.macWaitForElement(titled: "Move file tab to left: README.md", timeout: 5)
        TestStep.macScreenshot(label: "mac-split-hello-left-readme-right")

        // ── Phase 5: Persistence across session switch ──────────────
        TestStep.log("Phase 5: Switch to a different session and back; split state survives")
        TestStep.macClickButton(titled: "other")
        TestStep.wait(seconds: 2)
        // The arrow-icon AX labels for the file tabs should be gone while we're
        // viewing the other session — its `SessionFileTabsState` is empty.
        TestStep.macWaitForElementToDisappear(titled: "Move file tab to right: hello.txt", timeout: 5)
        TestStep.macScreenshot(label: "mac-split-other-session-no-tabs")

        TestStep.macClickButton(titled: "split")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "Move file tab to right: hello.txt", timeout: 5)
        TestStep.macWaitForElement(titled: "Move file tab to left: README.md", timeout: 5)
        TestStep.macScreenshot(label: "mac-split-restored-after-session-roundtrip")

        // ── Phase 6: alwaysOpenLinksInSplit routes a click to the right ─
        TestStep.log("Phase 6: Toggle 'Always open links in split tab' and click a terminal link")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        // Scroll the form so the new toggle is on screen even though the
        // Settings window is fixed-size on this macOS build.
        TestStep.macScrollWheel(deltaY: -5, count: 4)
        TestStep.wait(seconds: 0.5)
        // Click via the toggle's help string. AXPress on the visible title can
        // hit the Text label next to the switch instead of the switch itself,
        // mirroring the pattern in `TerminalFileLinkScenario`.
        TestStep.macClickButton(
            titled: "When opening a web link in an in-app browser tab, route it to the split-view right pane instead of the left."
        )
        TestStep.wait(seconds: 0.5)
        // Flip browserLinkBehavior to .alwaysInApp so the click doesn't pop
        // the "Open this link?" confirmation sheet. The picker now lives on
        // its own Browser tab (per-domain rules PR), not under General.
        TestStep.macSelectSettingsTab("Browser")
        TestStep.macWaitForWindow(titled: "Browser", timeout: 5)
        TestStep.macClickMenuItem(
            menuButtonTitle: "How http/https/ftp links clicked in the terminal should open by default. " +
                "Domain-specific rules below override this for matching hosts.",
            itemTitle: "Always in app"
        )
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-split-settings-toggled-on")
        // Switch back to General so the teardown (and any later scenario)
        // finds Settings on the tab it expects — Settings remembers the last
        // selected tab between opens.
        TestStep.macSelectSettingsTab("General")
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macCloseWindow(titled: "General")
        TestStep.wait(seconds: 1)

        // Click the terminal-link in the split:0 window. The new in-app
        // browser tab must land directly on the right pane.
        TestStep.macClickButton(titled: "split")
        TestStep.macClickButton(titled: "split:0")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-%0"), .valueContains("OPEN-LINK-EASY-CLICK-TARGET")]),
            timeout: 10
        )
        TestStep.macClickAtPoint(x: linkClickX, y: linkClickY)
        TestStep.wait(seconds: 2)
        // The browser tab arrow should read "to left", proving it lives on
        // the right pane.
        TestStep.macWaitForElementQuery(.labelContains("Move browser tab to left:"), timeout: 5)
        TestStep.macScreenshot(label: "mac-split-browser-tab-opens-on-right")

        // ── Phase 7: Close the last right-side tab → split collapses ─
        TestStep.log("Phase 7: Close every right-side tab; split collapses to single pane")
        // README.md is still on the right (Phases 3/4 left it there). Hello.txt
        // was moved back to the left. The new browser tab is on the right.
        // Close them one by one and verify the right pane goes away.
        TestStep.macClickButton(titled: "File tab: README.md")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Close file tab: README.md")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "File tab: README.md", timeout: 5)

        // The browser tab is still on the right and the split must still be
        // active — verify by checking its arrow label is still left-pointing.
        TestStep.macWaitForElementQuery(.labelContains("Move browser tab to left:"), timeout: 5)

        // Move hello.txt to the right, then back to the left so we exercise
        // the "move last tab off right" collapse path too. After the move
        // back, the browser tab is the only thing on the right.
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Move file tab to right: hello.txt")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "Move file tab to left: hello.txt", timeout: 5)
        TestStep.macClickButton(titled: "Move file tab to left: hello.txt")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "Move file tab to right: hello.txt", timeout: 5)

        // Now close the lone right-side browser tab — split should collapse.
        // The browser tab's accessibility close label uses the host portion of
        // the URL as the tab label (e.g. "Close browser tab: 127.0.0.1"). We
        // route a CGEvent click through the element matched by labelContains
        // so the assertion isn't tied to the exact host/port shape.
        TestStep.macCGClickElement(query: .labelContains("Close browser tab:"))
        TestStep.wait(seconds: 1)
        // After the close, no arrow icons should remain — every file/browser
        // tab is back to its single-pane "split" icon.
        TestStep.macWaitForElementToDisappear(titled: "Move file tab to right: hello.txt", timeout: 5)
        TestStep.macWaitForElementQueryToDisappear(.labelContains("Move browser tab to left:"), timeout: 5)
        TestStep.macWaitForElement(titled: "Open file tab in split: hello.txt", timeout: 5)
        TestStep.macScreenshot(label: "mac-split-collapsed-back-to-single")

        // ── Tear down ────────────────────────────────────────────
        // Turn the always-open-links-in-split setting back off so this state
        // doesn't leak into other scenarios that run on the same instance.
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macScrollWheel(deltaY: -5, count: 4)
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(
            titled: "When opening a web link in an in-app browser tab, route it to the split-view right pane instead of the left."
        )
        TestStep.wait(seconds: 0.5)
        TestStep.macCloseWindow(titled: "General")
        TestStep.wait(seconds: 1)

        Shortcut.tmuxRunCommand(target: "split:0", command: "exit")
        Shortcut.tmuxRunCommand(target: "other:0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
