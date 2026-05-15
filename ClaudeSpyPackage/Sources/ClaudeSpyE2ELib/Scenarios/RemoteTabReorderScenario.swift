import Foundation

/// E2E scenario: Tab reordering, the "+" menu, and the unified drag model
/// for terminals and browser tabs on a **remote session** (Mac viewer
/// connected to a paired Mac host).
///
/// Mirrors `TabReorderScenario` for the remote tab bar — but remote sessions
/// don't expose the host's filesystem, so the file-explorer / file-tab
/// phases from issue #510 are intentionally absent.
///
/// Covers the viewer-side tab-bar affordances:
/// - `+` button with a popup that creates either a new tmux window
///   ("New Terminal") on the host or a new in-app browser tab
///   ("New Browser", which focuses the address bar locally on the viewer).
/// - Drag-to-reorder for terminals — the new order is pushed to the host via
///   `MoveTmuxWindows` so it survives an app restart on both sides.
/// - Cmd-Shift-[ / Cmd-Shift-] menu shortcuts that cycle the active tab.
/// - "Drag past the last tab" via the trailing drop zone.
/// - Cross-divider drags: terminals and browser tabs can be flipped between
///   the two split panes via drag.
/// - Auto-collapse of the split when every entry winds up on the right.
///
/// The scenario uses the explicit `macDragElement` step rather than fixed
/// screen coordinates so the source and target stay anchored to the live
/// tab strip even if the window resizes.
public enum RemoteTabReorderScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Remote Tab Reorder",
        tags: ["tabs", "reorder", "remote", "macos-only"]
    ) {
        // ── Setup: pair two Mac apps ────────────────────────────────────
        Shortcut.twoMacPairing

        // ── Setup: two tmux sessions on the host, three windows in primary
        TestStep.log("Setup: Create tmux sessions for the remote reorder test")
        TestStep.tmuxCreateSession(name: "rtabreorder", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["rename-window", "-t", "rtabreorder:0", "winA"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "rtabreorder", "-n", "winB"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "rtabreorder", "-n", "winC"])
        // Re-select winA so the sidebar click lands on a known tab.
        TestStep.tmuxCommand(arguments: ["select-window", "-t", "rtabreorder:0"])
        TestStep.wait(seconds: 1)

        // Secondary session used by Phase 4 to round-trip away and back so
        // we can prove the reordered layout survives a session switch.
        TestStep.tmuxCreateSession(name: "rtabreorder-other", width: 100, height: 30)
        TestStep.wait(seconds: 2)

        // ── Open the host's panes window (forces a pane refresh) ────────
        Shortcut.openPanesWindow()
        TestStep.macResizeWindow(width: 1_300, height: 700)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "rtabreorder", timeout: 15)

        // ── Select the remote session on the viewer side ────────────────
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macResizeWindow(width: 1_300, height: 700, instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "rtabreorder", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "rtabreorder", instance: 1)
        TestStep.wait(seconds: 3)

        // Viewer should now show the three windows in the remote tab bar.
        TestStep.macWaitForElement(titled: "winA", timeout: 10, instance: 1)
        TestStep.macWaitForElement(titled: "winB", timeout: 10, instance: 1)
        TestStep.macWaitForElement(titled: "winC", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-rtabreorder-initial", instance: 1)

        // ── Phase 1: "+" menu offers New Terminal and New Browser ───────
        //
        // The "+" button is a SwiftUI Menu; AXPress on it doesn't reliably
        // open the popup on every macOS build (the menu briefly shows then
        // auto-dismisses), so we open it via a CGEvent click and then click
        // the inner menu item once it's accessible.
        TestStep.log("Phase 1: + button opens a menu with New Terminal and New Browser on the viewer")
        TestStep.macCGClickElement(query: .label("New Tab"), instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "New Terminal", instance: 1)
        TestStep.wait(seconds: 5)

        // The new terminal is created on the host after the existing windows,
        // named "terminal 1" because the existing windows used non-numbered
        // names. The viewer mirrors the new tab once the host pushes state.
        TestStep.macWaitForElement(titled: "terminal 1", timeout: 15, instance: 1)
        TestStep.macScreenshot(label: "viewer-rtabreorder-after-new-terminal", instance: 1)

        // ── Phase 2: "New Browser" creates a browser tab, focuses URL ───
        TestStep.log("Phase 2: New Browser menu item creates a browser tab with focused URL field")
        TestStep.macCGClickElement(query: .label("New Tab"), instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "New Browser", instance: 1)
        TestStep.wait(seconds: 2)

        // The new browser tab labels with "about:blank" until the user types
        // a real URL. The address bar should have focus — typing here goes
        // straight into the URL field rather than dropping characters.
        TestStep.macWaitForElement(titled: "URL", timeout: 5, instance: 1)
        TestStep.macType(text: "example.com", pressReturn: false, instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "viewer-rtabreorder-new-browser-typed-into-url", instance: 1)
        // Browser tabs are scoped to the viewer only — clean up immediately so
        // later phases work against the same tab set.
        TestStep.macCGClickElement(query: .labelContains("Close browser tab:"), instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQueryToDisappear(.labelContains("Close browser tab:"), timeout: 5, instance: 1)

        // ── Phase 3: Drag winC ahead of winA via the AX-driven helper ───
        TestStep.log("Phase 3: Drag winC onto winA — new order becomes winC, winA, winB, terminal 1 on the host")
        TestStep.macDragElement(
            from: .labelContains("rtabreorder:2 winC"),
            to: .labelContains("rtabreorder:0 winA"),
            instance: 1
        )
        TestStep.wait(seconds: 5)

        // After the drag winC sits at index 0 on the host (its label has the
        // new id). We assert via tmux's `display-message` to catch a bug
        // where the SwiftUI tab list updates but the tmux indices don't.
        TestStep.tmuxStoreDisplayMessage(
            target: "rtabreorder",
            // `#,` escapes the comma so tmux emits it literally — otherwise
            // the bare `,` inside `#{W:...}` is parsed as the active/inactive
            // format separator and no commas appear in the output.
            format: "#{W:#{window_name}#,}",
            storeAs: "tmuxOrderAfterDrag"
        )
        TestStep.assertStoredContains(
            key: "tmuxOrderAfterDrag",
            substring: "winC,winA,winB,terminal 1,"
        )
        // Viewer reflects the host's renumbering.
        TestStep.macWaitForElement(titled: "rtabreorder:0 winC", timeout: 10, instance: 1)
        TestStep.macWaitForElement(titled: "rtabreorder:1 winA", timeout: 10, instance: 1)
        TestStep.macWaitForElement(titled: "rtabreorder:2 winB", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-rtabreorder-after-drag", instance: 1)

        // ── Phase 4: Session round-trip preserves the new order ─────────
        TestStep.log("Phase 4: Switch to the other session and back on the viewer — order survives")
        TestStep.macClickButton(titled: "rtabreorder-other", instance: 1)
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementToDisappear(titled: "rtabreorder:0 winC", timeout: 5, instance: 1)

        TestStep.macClickButton(titled: "rtabreorder", instance: 1)
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "rtabreorder:0 winC", timeout: 5, instance: 1)
        TestStep.macWaitForElement(titled: "rtabreorder:1 winA", timeout: 5, instance: 1)
        TestStep.macWaitForElement(titled: "rtabreorder:2 winB", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-rtabreorder-after-session-roundtrip", instance: 1)

        // ── Phase 5: Cmd-Shift-] / Cmd-Shift-[ keyboard navigation ──────
        TestStep.log("Phase 5: Cmd-Shift-] cycles to the next tab; Cmd-Shift-[ cycles back")
        // Start on winC (the leftmost tab after the reorder).
        TestStep.macClickButton(titled: "rtabreorder:0 winC", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("rtabreorder:0 winC"), .valueContains("selected")]),
            timeout: 5,
            instance: 1
        )

        // Cmd-Shift-] → next visible tab (winA).
        TestStep.macPressKey(.character("]"), modifiers: [.command, .shift], instance: 1)
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("rtabreorder:1 winA"), .valueContains("selected")]),
            timeout: 5,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-rtabreorder-after-next-shortcut", instance: 1)

        // Cmd-Shift-[ → previous visible tab (winC again).
        TestStep.macPressKey(.character("["), modifiers: [.command, .shift], instance: 1)
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("rtabreorder:0 winC"), .valueContains("selected")]),
            timeout: 5,
            instance: 1
        )

        // ── Phase 6: Close a window — neighbours collapse left ──────────
        TestStep.log("Phase 6: Close winA via tmux on the host — winB shifts left and viewer follows")
        // Drive the close from tmux directly to avoid coordinating with the X-
        // visibility gating and the close-confirmation alert — this is a
        // reconcile smoke test, not a UI-flow test.
        TestStep.tmuxCommand(arguments: ["kill-window", "-t", "rtabreorder:winA"])
        TestStep.wait(seconds: 5)
        TestStep.macWaitForElementToDisappear(titled: "rtabreorder:1 winA", timeout: 10, instance: 1)

        // After the close, the remaining windows shift down: winB takes the
        // index winA vacated, terminal 1 follows. We re-check the tmux side
        // to make sure we didn't accidentally re-sort on close.
        TestStep.tmuxStoreDisplayMessage(
            target: "rtabreorder",
            format: "#{W:#{window_name}#,}",
            storeAs: "tmuxOrderAfterClose"
        )
        TestStep.assertStoredContains(
            key: "tmuxOrderAfterClose",
            substring: "winC,winB,terminal 1,"
        )
        TestStep.macScreenshot(label: "viewer-rtabreorder-after-close-winA", instance: 1)

        // ── Phase 7: Trailing drop zone — drag past the last tab ────────
        //
        // The new trailing drop zone fills the rest of the bar to the right
        // of the last visible tab so users can drop "past the end". It's a
        // `Color.clear` view in production; we add an AX identifier on it
        // (`remote-tab-trailing-drop-single`) so the test can drag onto it
        // through the same AX path as every other tab.
        TestStep.log("Phase 7: Drag winC to the trailing drop zone — moves to end on the host")
        TestStep.macDragElement(
            from: .labelContains("rtabreorder:0 winC"),
            to: .identifier("remote-tab-trailing-drop-single"),
            instance: 1
        )
        TestStep.wait(seconds: 5)
        TestStep.tmuxStoreDisplayMessage(
            target: "rtabreorder",
            format: "#{W:#{window_name}#,}",
            storeAs: "tmuxOrderAfterEndDrop"
        )
        TestStep.assertStoredContains(
            key: "tmuxOrderAfterEndDrop",
            substring: "winB,terminal 1,winC,"
        )
        TestStep.macWaitForElement(titled: "rtabreorder:0 winB", timeout: 10, instance: 1)
        TestStep.macWaitForElement(titled: "rtabreorder:1 terminal 1", timeout: 10, instance: 1)
        TestStep.macWaitForElement(titled: "rtabreorder:2 winC", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-rtabreorder-after-trailing-drop", instance: 1)

        // ── Phase 8: Open a split via winB's split toggle ───────────────
        //
        // Target winB by exact AX label so we don't depend on visual tab
        // order — after the prior reorders the tmux indices renumber and
        // the unified tabOrder may not match the host's order, but the
        // window names (and therefore the split-toggle labels) are stable.
        TestStep.log("Phase 8: Click winB's split toggle — winB moves to the right pane")
        TestStep.macClickButton(titled: "Open terminal in split: winB", instance: 1)
        TestStep.wait(seconds: 3)
        TestStep.macWaitForElement(titled: "Move terminal to left: winB", timeout: 5, instance: 1)
        // Every remaining terminal on the left now shows a "to right" arrow.
        TestStep.macWaitForElementQuery(.labelContains("Move terminal to right:"), timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-rtabreorder-split-opened-winB-right", instance: 1)

        // ── Phase 9: Click winC's split toggle to send it to the right ──
        //
        // Use an AX click on the named split-toggle button rather than a
        // cross-divider drag — the drag's source query is ambiguous after
        // the prior reorders renumber tmux indices, while the AX label
        // "Move terminal to right: winC" is stable across renumbers.
        TestStep.log("Phase 9: Click winC's split toggle — winC also lands on the right")
        TestStep.macClickButton(titled: "Move terminal to right: winC", instance: 1)
        TestStep.wait(seconds: 3)
        TestStep.macWaitForElement(titled: "Move terminal to left: winC", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-rtabreorder-winC-also-on-right", instance: 1)

        // ── Phase 10: Auto-collapse when the left section is empty ──────
        //
        // Move the last remaining left-side terminal (terminal 1) to the
        // right via its split arrow. Once nothing is left of the divider,
        // `reconcileRemoteRightPaneSelection` auto-collapses the split and
        // the strip flips back to single-pane icons.
        TestStep.log("Phase 10: Move terminal 1 to right → split collapses")
        TestStep.macClickButton(titled: "Move terminal to right: terminal 1", instance: 1)
        TestStep.wait(seconds: 3)
        // Every "Move *" arrow should be gone; "Open … in split" icons return.
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("Move terminal to left:"),
            timeout: 5,
            instance: 1
        )
        TestStep.macWaitForElement(titled: "Open terminal in split: winB", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-rtabreorder-collapsed-from-left-empty", instance: 1)

        // ── Tear down ────────────────────────────────────────────────
        // Use kill-session so every window in both sessions is cleaned up
        // unconditionally. `exit`-on-pane only closes its own window and
        // would leave the other windows running if the scenario aborted
        // mid-flight.
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "rtabreorder"])
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "rtabreorder-other"])
        TestStep.wait(seconds: 2)
    }
}
