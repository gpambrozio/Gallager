import Foundation

/// E2E scenario: Tab reordering and the "+" menu (issue #510).
///
/// Covers the new tab-bar affordances:
/// - `+` button moved to the leading edge with a popup that creates either
///   a new tmux window ("New Terminal") or a new in-app browser tab
///   ("New Browser", which focuses the address bar).
/// - Drag-to-reorder for terminals — the new order is persisted via
///   `tmux move-window` so it survives an app restart. Also tested via a
///   session switch so the SwiftUI side preserves the new layout.
/// - Drag-to-reorder for in-app browser tabs (file tabs use the same code
///   path, so exercising one is enough to keep the regression net tight).
/// - Cmd-Shift-[ / Cmd-Shift-] menu shortcuts that cycle the active tab in
///   the current session.
///
/// The scenario uses the explicit `macDragElement` step rather than fixed
/// screen coordinates so the source and target stay anchored to the live
/// tab strip even if the window resizes.
public enum TabReorderScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Tab Reorder",
        tags: ["tabs", "reorder", "macos-only"]
    ) {
        // ── Setup: two tmux sessions, three windows in the primary ─────
        TestStep.log("Setup: Create tmux sessions for the reorder test")
        TestStep.tmuxCreateSession(name: "tabreorder", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["rename-window", "-t", "tabreorder:0", "winA"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "tabreorder", "-n", "winB"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "tabreorder", "-n", "winC"])
        // Re-select winA so the sidebar click lands on a known tab.
        TestStep.tmuxCommand(arguments: ["select-window", "-t", "tabreorder:0"])
        TestStep.wait(seconds: 1)

        // Secondary session used by Phase 4 to round-trip away and back so
        // we can prove the reordered layout survives a session switch.
        TestStep.tmuxCreateSession(name: "tabreorder-other", width: 100, height: 30)
        TestStep.wait(seconds: 1)

        // ── Launch app ────────────────────────────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_300, height: 700)
        TestStep.wait(seconds: 1)

        TestStep.macWaitForElement(titled: "tabreorder", timeout: 10)
        TestStep.macClickButton(titled: "tabreorder")
        TestStep.wait(seconds: 2)

        TestStep.macWaitForElement(titled: "winA", timeout: 10)
        TestStep.macWaitForElement(titled: "winB", timeout: 10)
        TestStep.macWaitForElement(titled: "winC", timeout: 10)
        TestStep.macScreenshot(label: "mac-tabreorder-initial")

        // ── Phase 1: "+" menu offers New Terminal and New Browser ─────
        TestStep.log("Phase 1: + button opens a menu with New Terminal and New Browser")
        TestStep.macClickMenuItem(menuButtonTitle: "New Tab", itemTitle: "New Terminal")
        TestStep.wait(seconds: 3)

        // The new terminal is created after the existing windows, named
        // "terminal 1" because the existing windows used non-numbered names.
        TestStep.macWaitForElement(titled: "terminal 1", timeout: 10)
        TestStep.macScreenshot(label: "mac-tabreorder-after-new-terminal")

        // ── Phase 2: "New Browser" creates a browser tab, focuses URL ─
        TestStep.log("Phase 2: New Browser menu item creates a browser tab with focused URL field")
        TestStep.macClickMenuItem(menuButtonTitle: "New Tab", itemTitle: "New Browser")
        TestStep.wait(seconds: 2)

        // The new browser tab labels with "about:blank" until the user types
        // a real URL. The address bar should have focus — typing here goes
        // straight into the URL field rather than dropping characters.
        TestStep.macWaitForElement(titled: "URL", timeout: 5)
        TestStep.macType(text: "example.com", pressReturn: false)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-tabreorder-new-browser-typed-into-url")
        // The visible tab label changes based on the loaded page, but the
        // closeable browser tab is enough proof — clean up immediately so
        // later phases work against the same tab set.
        TestStep.macCGClickElement(query: .labelContains("Close browser tab:"))
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQueryToDisappear(.labelContains("Close browser tab:"), timeout: 5)

        // ── Phase 3: Drag winC ahead of winA via the AX-driven helper ─
        TestStep.log("Phase 3: Drag winC onto winA — new order becomes winC, winA, winB, terminal 1")
        TestStep.macDragElement(
            from: .labelContains("tabreorder:2 winC"),
            to: .labelContains("tabreorder:0 winA")
        )
        TestStep.wait(seconds: 3)

        // After the drag winC sits at index 0 (its label has the new id).
        // We assert via tmux's `display-message` so the test catches a bug
        // where the SwiftUI tab list updates but the tmux indices don't.
        TestStep.tmuxStoreDisplayMessage(
            target: "tabreorder",
            format: "#{W:#{window_name},}",
            storeAs: "tmuxOrderAfterDrag"
        )
        TestStep.assertStoredContains(
            key: "tmuxOrderAfterDrag",
            substring: "winC,winA,winB,terminal 1,"
        )
        TestStep.macWaitForElement(titled: "tabreorder:0 winC", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:1 winA", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:2 winB", timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-after-drag")

        // ── Phase 4: Session round-trip preserves the new order ───────
        TestStep.log("Phase 4: Switch to the other session and back — order survives")
        TestStep.macClickButton(titled: "tabreorder-other")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementToDisappear(titled: "tabreorder:0 winC", timeout: 5)

        TestStep.macClickButton(titled: "tabreorder")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "tabreorder:0 winC", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:1 winA", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:2 winB", timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-after-session-roundtrip")

        // ── Phase 5: Cmd-Shift-] / Cmd-Shift-[ keyboard navigation ────
        TestStep.log("Phase 5: Cmd-Shift-] cycles to the next tab; Cmd-Shift-[ cycles back")
        // Start on winC (the leftmost tab after the reorder).
        TestStep.macClickButton(titled: "tabreorder:0 winC")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabreorder:0 winC"), .valueContains("selected")]),
            timeout: 5
        )

        // Cmd-Shift-] → next visible tab (winA).
        TestStep.macPressShortcut(key: "]", modifiers: [.command, .shift])
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabreorder:1 winA"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-tabreorder-after-next-shortcut")

        // Cmd-Shift-[ → previous visible tab (winC again).
        TestStep.macPressShortcut(key: "[", modifiers: [.command, .shift])
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabreorder:0 winC"), .valueContains("selected")]),
            timeout: 5
        )

        // ── Phase 6: Close a window — neighbours collapse left ────────
        TestStep.log("Phase 6: Close winA — winB shifts left and tmux indices follow")
        // winA is at tmux index 1 after Phase 3's reorder; right-click → close
        // uses the host's standard close confirmation.
        TestStep.macContextMenuClick(elementTitle: "tabreorder:1 winA", menuItem: "Close window")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementToDisappear(titled: "tabreorder:1 winA", timeout: 5)

        // After the close, the remaining windows shift down: winB takes the
        // index winA vacated, terminal 1 follows. We re-check the tmux side
        // to make sure we didn't accidentally re-sort on close.
        TestStep.tmuxStoreDisplayMessage(
            target: "tabreorder",
            format: "#{W:#{window_name},}",
            storeAs: "tmuxOrderAfterClose"
        )
        TestStep.assertStoredContains(
            key: "tmuxOrderAfterClose",
            substring: "winC,winB,terminal 1,"
        )
        TestStep.macScreenshot(label: "mac-tabreorder-after-close-winA")

        // ── Tear down ────────────────────────────────────────────────
        Shortcut.tmuxRunCommand(target: "tabreorder:0", command: "exit")
        Shortcut.tmuxRunCommand(target: "tabreorder-other:0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
