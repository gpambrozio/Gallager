import Foundation

/// E2E scenario: Session color synchronization across all three platforms.
///
/// Verifies that custom session colors picked from the right-click "Set
/// Color" submenu sync between the macOS host, a macOS viewer, and an iOS
/// viewer for several sessions in the same sidebar — each platform must
/// render every session's bar with the right colour, independently of the
/// others.
///
/// Three sessions named `e2e-color-a`, `e2e-color-b`, and `e2e-color-c` are
/// created on the host. The scenario:
///   1. Picks distinct colors for each via the right-click → "Set Color"
///      submenu and verifies all three platforms reflect every choice.
///   2. Changes one session's colour from the "Color: <Name>" submenu to
///      prove re-pick (rather than fresh set) also propagates everywhere.
///   3. Clears one session's colour via the top-level "Clear Color" entry
///      and verifies the bar disappears on every platform while the other
///      two sessions keep their colours.
///   4. Clears the remaining two so all three sessions end up uncoloured.
///
/// All colour mutations go through the right-click context menu — never
/// `tmux set-option` — so the menu wiring (`ColorContextMenuButtons` →
/// `MirrorWindowManager.setSessionColor` → `TmuxService.setSessionColor`)
/// is exercised end-to-end. Each platform exposes the bar with
/// `accessibilityLabel("<Name> color")`, so the same `*-color` element
/// query works on host, Mac viewer, and iOS viewer alike.
public enum SessionColorSyncScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Session Color Sync",
        tags: ["color", "sync"]
    ) {
        // ── Phase 1: Pair host with iOS viewer + Mac viewer ─────────────

        FreshPairingScenario.scenario
        Shortcut.addMacViewer

        // ── Phase 2: Create three Claude sessions on the host ───────────
        //
        // Each session gets a distinct `SessionStart` hook so the sidebar
        // shows its project name (more user-recognisable than the raw
        // tmux session name).

        TestStep.tmuxCreateSession(name: "e2e-color-a", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "e2e-color-b", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "e2e-color-c", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        TestStep.tmuxStorePaneId(target: "e2e-color-a:0.0", storeAs: "paneIdA")
        TestStep.tmuxStorePaneId(target: "e2e-color-b:0.0", storeAs: "paneIdB")
        TestStep.tmuxStorePaneId(target: "e2e-color-c:0.0", storeAs: "paneIdC")

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-color-a-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneIdA}",
            projectPath: "/Users/test/AlphaProject"
        )
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-color-b-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneIdB}",
            projectPath: "/Users/test/BravoProject"
        )
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-color-c-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneIdC}",
            projectPath: "/Users/test/CharlieProject"
        )
        TestStep.wait(seconds: 3)

        // ── Phase 3: Open the Panes window on host + viewer ─────────────

        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "AlphaProject", timeout: 30)
        TestStep.macWaitForElement(titled: "BravoProject", timeout: 30)
        TestStep.macWaitForElement(titled: "CharlieProject", timeout: 30)

        TestStep.wait(seconds: 3)
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macWaitForElement(titled: "AlphaProject", timeout: 30, instance: 1)
        TestStep.macWaitForElement(titled: "BravoProject", timeout: 30, instance: 1)
        TestStep.macWaitForElement(titled: "CharlieProject", timeout: 30, instance: 1)

        TestStep.iosWaitForElement(.labelContains("AlphaProject"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("BravoProject"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("CharlieProject"), timeout: 15)

        TestStep.macScreenshot(label: "host-before-color")
        TestStep.macScreenshot(label: "viewer-before-color", instance: 1)
        TestStep.iosScreenshot(label: "ios-before-color")

        // ── Phase 4: Set distinct colours via "Set Color" submenu ──────
        //
        // Each pick is done through the host's right-click → "Set Color"
        // submenu. The bar then has to land on every platform before the
        // next session is touched, otherwise we wouldn't be testing
        // simultaneous propagation.

        TestStep.log("Host setting AlphaProject → Red via context menu")

        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-color-a",
            parentMenuItem: "Set Color",
            submenuItem: "Red"
        )
        TestStep.wait(seconds: 2)

        TestStep.macWaitForElement(titled: "Red color", timeout: 15)
        TestStep.macWaitForElement(titled: "Red color", timeout: 15, instance: 1)
        TestStep.iosWaitForElement(.labelContains("Red color"), timeout: 20)

        TestStep.log("Host setting BravoProject → Green via context menu")

        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-color-b",
            parentMenuItem: "Set Color",
            submenuItem: "Green"
        )
        TestStep.wait(seconds: 2)

        TestStep.macWaitForElement(titled: "Green color", timeout: 15)
        TestStep.macWaitForElement(titled: "Green color", timeout: 15, instance: 1)
        TestStep.iosWaitForElement(.labelContains("Green color"), timeout: 20)

        TestStep.log("Host setting CharlieProject → Blue via context menu")

        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-color-c",
            parentMenuItem: "Set Color",
            submenuItem: "Blue"
        )
        TestStep.wait(seconds: 2)

        TestStep.macWaitForElement(titled: "Blue color", timeout: 15)
        TestStep.macWaitForElement(titled: "Blue color", timeout: 15, instance: 1)
        TestStep.iosWaitForElement(.labelContains("Blue color"), timeout: 20)

        // All three colours must coexist on every platform.
        TestStep.macScreenshot(label: "host-after-set-three")
        TestStep.macScreenshot(label: "viewer-after-set-three", instance: 1)
        TestStep.iosScreenshot(label: "ios-after-set-three")

        // ── Phase 5: Re-pick BravoProject from "Color: Green" → Purple ──
        //
        // When a colour is already set, the parent label shows
        // "Color: <Name>" instead of "Set Color". Re-picking must replace
        // the colour and propagate the new value, not stack a second one.

        TestStep.log("Host changing BravoProject → Purple via 'Color: Green' submenu")

        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-color-b",
            parentMenuItem: "Color: Green",
            submenuItem: "Purple"
        )
        TestStep.wait(seconds: 2)

        // Green must be gone everywhere, replaced by Purple. Red and Blue
        // are unaffected.
        TestStep.macWaitForElementToDisappear(titled: "Green color", timeout: 15)
        TestStep.macWaitForElement(titled: "Purple color", timeout: 15)
        TestStep.macWaitForElement(titled: "Red color", timeout: 15)
        TestStep.macWaitForElement(titled: "Blue color", timeout: 15)

        TestStep.macWaitForElementToDisappear(titled: "Green color", timeout: 15, instance: 1)
        TestStep.macWaitForElement(titled: "Purple color", timeout: 15, instance: 1)

        TestStep.iosWaitForElementToDisappear(.labelContains("Green color"), timeout: 20)
        TestStep.iosWaitForElement(.labelContains("Purple color"), timeout: 20)

        TestStep.macScreenshot(label: "host-after-repick")
        TestStep.macScreenshot(label: "viewer-after-repick", instance: 1)
        TestStep.iosScreenshot(label: "ios-after-repick")

        // ── Phase 6: Clear AlphaProject's colour via "Clear Color" ──────
        //
        // "Clear Color" is a top-level destructive button, not a submenu
        // entry, so the existing single-level `macContextMenuClick` works.
        // Bravo (Purple) and Charlie (Blue) must remain coloured — this
        // catches regressions where the wrong session would lose its
        // colour because of tmux target ambiguity.

        TestStep.log("Host clearing AlphaProject's colour via 'Clear Color'")

        TestStep.macContextMenuClick(
            elementTitle: "e2e-color-a",
            menuItem: "Clear Color"
        )
        TestStep.wait(seconds: 2)

        TestStep.macWaitForElementToDisappear(titled: "Red color", timeout: 15)
        TestStep.macWaitForElement(titled: "Purple color", timeout: 15)
        TestStep.macWaitForElement(titled: "Blue color", timeout: 15)

        TestStep.macWaitForElementToDisappear(titled: "Red color", timeout: 15, instance: 1)
        TestStep.macWaitForElement(titled: "Purple color", timeout: 15, instance: 1)
        TestStep.macWaitForElement(titled: "Blue color", timeout: 15, instance: 1)

        TestStep.iosWaitForElementToDisappear(.labelContains("Red color"), timeout: 20)
        TestStep.iosWaitForElement(.labelContains("Purple color"), timeout: 20)
        TestStep.iosWaitForElement(.labelContains("Blue color"), timeout: 20)

        TestStep.macScreenshot(label: "host-after-clear-one")
        TestStep.macScreenshot(label: "viewer-after-clear-one", instance: 1)
        TestStep.iosScreenshot(label: "ios-after-clear-one")

        // ── Phase 7: Clear the remaining two so the sidebar ends bare ───

        TestStep.log("Host clearing BravoProject and CharlieProject")

        TestStep.macContextMenuClick(
            elementTitle: "e2e-color-b",
            menuItem: "Clear Color"
        )
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementToDisappear(titled: "Purple color", timeout: 15)

        TestStep.macContextMenuClick(
            elementTitle: "e2e-color-c",
            menuItem: "Clear Color"
        )
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementToDisappear(titled: "Blue color", timeout: 15)

        TestStep.macWaitForElementToDisappear(titled: "Purple color", timeout: 15, instance: 1)
        TestStep.macWaitForElementToDisappear(titled: "Blue color", timeout: 15, instance: 1)

        TestStep.iosWaitForElementToDisappear(.labelContains("Purple color"), timeout: 20)
        TestStep.iosWaitForElementToDisappear(.labelContains("Blue color"), timeout: 20)

        TestStep.macScreenshot(label: "host-after-clear-all")
        TestStep.macScreenshot(label: "viewer-after-clear-all", instance: 1)
        TestStep.iosScreenshot(label: "ios-after-clear-all")
    }
}
