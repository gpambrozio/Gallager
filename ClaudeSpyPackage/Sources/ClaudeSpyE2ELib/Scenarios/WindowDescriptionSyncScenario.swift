import Foundation

/// E2E scenario: Window description + color synchronization across all three platforms
///
/// Verifies that custom window descriptions and colors sync between macOS host,
/// iOS viewer, and macOS viewer:
/// 1. Host adds a description via context menu → iOS and Mac viewer see it
/// 2. Mac viewer edits the description via context menu → host and iOS see it
/// 3. Host removes the description → all platforms reflect the removal
/// 4. Host picks a color via the "Set Color" submenu → dot appears on every
///    platform; clearing the color removes the dot.
/// 5. Host re-adds a description and color, is terminated + relaunched, and
///    both persist (stored as `@gallager-description` and `@gallager-color`
///    tmux user options).
public enum WindowDescriptionSyncScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Window Description Sync",
        tags: ["description", "sync"]
    ) {
        // ── Phase 1: Pair macOS host with iOS viewer ────────────────────

        FreshPairingScenario.scenario

        // ── Phase 2: Pair macOS host with Mac viewer (instance 1) ───────

        Shortcut.addMacViewer

        // ── Phase 3: Create Claude session on host ──────────────────────

        TestStep.tmuxCreateSession(name: "e2e-desc", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        TestStep.tmuxStorePaneId(target: "e2e-desc:0.0", storeAs: "paneId")

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-desc-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/DescProject"
        )
        TestStep.wait(seconds: 3)

        // ── Phase 4: Open Panes windows and set fixed sizes ─────────────

        // Host shows window ID in sidebar
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "e2e-desc", timeout: 30)
        TestStep.macWaitForElement(titled: "DescProject", timeout: 30)

        // Viewer shows project name in sidebar (like iOS)
        TestStep.wait(seconds: 3)
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macScreenshot(label: "viewer-panes-opened", instance: 1)
        TestStep.macWaitForElement(titled: "DescProject", timeout: 30, instance: 1)

        TestStep.iosWaitForElement(.labelContains("DescProject"), timeout: 15)

        TestStep.macScreenshot(label: "host-before-description")
        TestStep.macScreenshot(label: "viewer-before-description", instance: 1)
        TestStep.iosScreenshot(label: "ios-before-description")

        // ── Phase 5: Host adds description via context menu ─────────────

        TestStep.log("Host adding description via context menu")

        TestStep.macContextMenuClick(elementTitle: "e2e-desc", menuItem: "Add Description")
        TestStep.macWaitForElement(titled: "Session Description", timeout: 5)
        TestStep.macScreenshot(label: "host-alert-add")
        TestStep.wait(seconds: 0.5)
        TestStep.macPressTab()
        TestStep.macType(text: "My Test Description", pressReturn: false)
        TestStep.macScreenshot(label: "host-alert-add-typed")
        TestStep.macClickButton(titled: "Save")
        TestStep.wait(seconds: 2)

        // Verify on all three platforms
        TestStep.macWaitForElement(titled: "My Test Description", timeout: 10)
        TestStep.macScreenshot(label: "host-after-add")

        TestStep.macWaitForElement(titled: "My Test Description", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-after-add", instance: 1)

        TestStep.iosWaitForElement(.labelContains("My Test Description"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-after-add")

        // ── Phase 6: Mac viewer edits description via context menu ──────

        TestStep.log("Mac viewer editing description via context menu")

        TestStep.macContextMenuClick(elementTitle: "My Test Description", menuItem: "Edit Description", instance: 1)
        TestStep.macWaitForElement(titled: "Session Description", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-alert-edit", instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macPressTab(instance: 1)
        TestStep.macSelectAll(instance: 1)
        TestStep.macType(text: "Viewer Updated", pressReturn: false, instance: 1)
        TestStep.macScreenshot(label: "viewer-alert-edit-typed", instance: 1)
        TestStep.macClickButton(titled: "Save", instance: 1)
        TestStep.wait(seconds: 2)

        // Verify on all three platforms
        TestStep.macWaitForElement(titled: "Viewer Updated", timeout: 10)
        TestStep.macScreenshot(label: "host-after-viewer-edit")

        TestStep.macWaitForElement(titled: "Viewer Updated", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-after-viewer-edit", instance: 1)

        TestStep.iosWaitForElement(.labelContains("Viewer Updated"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-after-viewer-edit")

        // ── Phase 7: Host removes description via context menu ──────────

        TestStep.log("Host removing description via context menu")

        TestStep.macContextMenuClick(elementTitle: "Viewer Updated", menuItem: "Remove Description")
        TestStep.wait(seconds: 2)

        // Verify removed on all three platforms
        TestStep.macWaitForElementToDisappear(titled: "Viewer Updated", timeout: 5)
        TestStep.macWaitForElement(titled: "e2e-desc", timeout: 5)

        TestStep.macWaitForElementToDisappear(titled: "Viewer Updated", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-after-remove", instance: 1)

        TestStep.iosWaitForElement(.labelContains("DescProject"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-after-remove")

        // ── Phase 8: Host sets a color via tmux user option ────────────────
        //
        // The right-click menu has a "Set Color" submenu with one item per
        // SessionColor case. AX automation can't reliably hover into a
        // submenu, so we drive the option directly via `tmux set-option`
        // (the same path the menu eventually writes through). This still
        // exercises the read side: the host's refresh loop picks up the
        // `@gallager-color` value and renders the dot, which then syncs
        // through the relay to viewers.

        TestStep.log("Setting session color via tmux user option")

        TestStep.tmuxCommand(arguments: ["set-option", "-t", "e2e-desc", "@gallager-color", "blue"])
        TestStep.wait(seconds: 3)

        // Each platform exposes the dot with `accessibilityLabel("Blue color")`,
        // so the same query works on host, Mac viewer, and iOS viewer.
        TestStep.macWaitForElement(titled: "Blue color", timeout: 15)
        TestStep.macScreenshot(label: "host-after-color-set")

        TestStep.macWaitForElement(titled: "Blue color", timeout: 15, instance: 1)
        TestStep.macScreenshot(label: "viewer-after-color-set", instance: 1)

        TestStep.iosWaitForElement(.labelContains("Blue color"), timeout: 20)
        TestStep.iosScreenshot(label: "ios-after-color-set")

        // ── Phase 9: Host clears the color ────────────────────────────────

        TestStep.log("Clearing session color via tmux user option")

        TestStep.tmuxCommand(arguments: ["set-option", "-u", "-t", "e2e-desc", "@gallager-color"])
        TestStep.wait(seconds: 3)

        TestStep.macWaitForElementToDisappear(titled: "Blue color", timeout: 15)
        TestStep.macScreenshot(label: "host-after-color-clear")

        // ── Phase 10: Restart host to verify description + color persistence ─
        //
        // Descriptions and colors are stored as tmux user options
        // (`@gallager-description`, `@gallager-color`) so they should survive
        // the host app being killed and relaunched. Viewers are lost on
        // restart (in-memory pairings under --e2e-test), so this phase only
        // checks the host side.

        TestStep.log("Re-adding description and color, then restarting host to verify persistence")

        TestStep.macContextMenuClick(elementTitle: "e2e-desc", menuItem: "Add Description")
        TestStep.macWaitForElement(titled: "Session Description", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macPressTab()
        TestStep.macType(text: "Persist Across Restart", pressReturn: false)
        TestStep.macClickButton(titled: "Save")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "Persist Across Restart", timeout: 10)

        TestStep.tmuxCommand(arguments: ["set-option", "-t", "e2e-desc", "@gallager-color", "green"])
        TestStep.wait(seconds: 3)
        TestStep.macWaitForElement(titled: "Green color", timeout: 15)
        TestStep.macScreenshot(label: "host-before-restart")

        TestStep.terminateMacApp()
        TestStep.wait(seconds: 2)
        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)
        Shortcut.openPanesWindow()

        // The session row should come back labelled with the persisted description
        // and the persisted color dot, hydrated from the tmux user options on
        // the first refresh after launch.
        TestStep.macWaitForElement(titled: "Persist Across Restart", timeout: 30)
        TestStep.macWaitForElement(titled: "Green color", timeout: 30)
        TestStep.macScreenshot(label: "host-after-restart")
    }
}
