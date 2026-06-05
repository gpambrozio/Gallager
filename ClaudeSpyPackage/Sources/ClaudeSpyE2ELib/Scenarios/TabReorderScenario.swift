import Foundation

/// E2E scenario: Tab reordering, the "+" menu, and the unified drag model
/// for terminals / file tabs / file explorer / browsers (issue #510).
///
/// Covers the tab-bar affordances:
/// - `+` button moved to the leading edge with a popup that creates either
///   a new tmux window ("New Terminal") or a new in-app browser tab
///   ("New Browser", which focuses the address bar).
/// - Drag-to-reorder for terminals — the new order is persisted via
///   `tmux move-window` so it survives an app restart. Also tested via a
///   session switch so the SwiftUI side preserves the new layout.
/// - Cmd-Shift-[ / Cmd-Shift-] menu shortcuts that cycle the active tab in
///   the current session.
/// - "Drag past the last tab" via the trailing drop zone.
/// - Cross-divider drags: terminals, the file explorer, file tabs, and
///   browser tabs can all be flipped between the two split panes via drag.
/// - Auto-collapse of the split when every entry winds up on the right.
/// - The right pane self-heals when the only right-side terminal exits.
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
        // `new-session` pins winA to $HOME (`-c`), but `new-window` inherits the
        // tmux *server's* working directory — the e2e binary's checkout/worktree
        // dir on CI, the repo root locally. That folder name would otherwise leak
        // into winB/winC's terminal prompt, the file-browser breadcrumb (Phase 8),
        // and the sidebar current-path line, making the screenshots differ between
        // checkout locations. Reset both to $HOME so every cwd the app surfaces is
        // stable regardless of where the suite runs. (The app-created "terminal 1"
        // already inherits winA's $HOME, so it needs no reset.)
        Shortcut.tmuxRunCommand(target: "tabreorder:winB", command: "cd; clear")
        Shortcut.tmuxRunCommand(target: "tabreorder:winC", command: "cd; clear")
        // Re-select winA so the sidebar click lands on a known tab.
        TestStep.tmuxCommand(arguments: ["select-window", "-t", "tabreorder:0"])
        TestStep.wait(seconds: 1)

        // Secondary session used by Phase 4 to round-trip away and back so
        // we can prove the reordered layout survives a session switch.
        TestStep.tmuxCreateSession(name: "tabreorder-other", width: 100, height: 30)
        TestStep.wait(seconds: 1)

        // Give both sessions a stable custom title — same mechanism the CLI uses
        // (`gallager set-title` / `new-session --title`), persisted as the
        // `@gallager-description` tmux user option. This drives the window title
        // bar and the sidebar primary label, so neither falls back to the
        // working-directory path (which varies by checkout folder). Set before
        // the app launches so the first session read already sees the titles.
        TestStep.tmuxCommand(arguments: ["set-option", "-t", "=tabreorder:", "@gallager-description", "Tab Reorder"])
        TestStep.tmuxCommand(arguments: ["set-option", "-t", "=tabreorder-other:", "@gallager-description", "Tab Reorder Other"])

        // ── Launch app ────────────────────────────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_300, height: 700)
        // Re-pin the sidebar after this second resize: `.balanced` NavigationSplitView
        // reflows column widths on resize, so without this the sidebar width is
        // non-deterministic across runs and the screenshots flake.
        TestStep.macSetSidebarWidth(250)

        TestStep.macWaitForElement(titled: "tabreorder", timeout: 10)
        TestStep.macClickButton(titled: "tabreorder")

        TestStep.macWaitForElement(titled: "winA", timeout: 10)
        TestStep.macWaitForElement(titled: "winB", timeout: 10)
        TestStep.macWaitForElement(titled: "winC", timeout: 10)
        TestStep.macScreenshot(label: "mac-tabreorder-initial")

        // ── Phase 1: "+" menu offers New Terminal and New Browser ─────
        //
        // The "+" button is a SwiftUI Menu; AXPress on it doesn't reliably
        // open the popup on every macOS build (the menu briefly shows then
        // auto-dismisses), so we open it via a CGEvent click and then click
        // the inner menu item once it's accessible.
        TestStep.log("Phase 1: + button opens a menu with New Terminal and New Browser")
        TestStep.macCGClickElement(query: .label("New Tab"))
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "New Terminal")

        // The new terminal is created after the existing windows, named
        // "terminal 1" because the existing windows used non-numbered names.
        TestStep.macWaitForElement(titled: "terminal 1", timeout: 10)
        TestStep.macScreenshot(label: "mac-tabreorder-after-new-terminal")

        // ── Phase 2: "New Browser" creates a browser tab, focuses URL ─
        TestStep.log("Phase 2: New Browser menu item creates a browser tab with focused URL field")
        TestStep.macCGClickElement(query: .label("New Tab"))
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "New Browser")

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
        TestStep.macWaitForElement(titled: "tabreorder:0 winC", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:1 winA", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:2 winB", timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-after-drag")

        // ── Phase 4: Session round-trip preserves the new order ───────
        TestStep.log("Phase 4: Switch to the other session and back — order survives")
        TestStep.macClickButton(titled: "tabreorder-other")
        TestStep.macWaitForElementToDisappear(titled: "tabreorder:0 winC", timeout: 5)

        TestStep.macClickButton(titled: "tabreorder")
        TestStep.macWaitForElement(titled: "tabreorder:0 winC", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:1 winA", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:2 winB", timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-after-session-roundtrip")

        // ── Phase 5: Cmd-Shift-] / Cmd-Shift-[ keyboard navigation ────
        TestStep.log("Phase 5: Cmd-Shift-] cycles to the next tab; Cmd-Shift-[ cycles back")
        // Start on winC (the leftmost tab after the reorder).
        TestStep.macClickButton(titled: "tabreorder:0 winC")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabreorder:0 winC"), .valueContains("selected")]),
            timeout: 5
        )

        // Cmd-Shift-] → next visible tab (winA).
        TestStep.macPressKey(.character("]"), modifiers: [.command, .shift])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabreorder:1 winA"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-tabreorder-after-next-shortcut")

        // Cmd-Shift-[ → previous visible tab (winC again).
        TestStep.macPressKey(.character("["), modifiers: [.command, .shift])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabreorder:0 winC"), .valueContains("selected")]),
            timeout: 5
        )

        // ── Phase 6: Close a window — neighbours collapse left ────────
        TestStep.log("Phase 6: Close winA via tmux — winB shifts left and indices follow")
        // The tab's context menu only carries Rename; the close affordance is
        // the dedicated X button (shown on hover/selection). Drive the close
        // from tmux directly to avoid coordinating with the X-visibility
        // gating and the close-confirmation alert — this is a reconcile
        // smoke test, not a UI-flow test.
        TestStep.tmuxCommand(arguments: ["kill-window", "-t", "tabreorder:winA"])
        TestStep.macWaitForElementToDisappear(titled: "tabreorder:1 winA", timeout: 5)

        // After the close, the remaining windows shift down: winB takes the
        // index winA vacated, terminal 1 follows. We re-check the tmux side
        // to make sure we didn't accidentally re-sort on close.
        TestStep.tmuxStoreDisplayMessage(
            target: "tabreorder",
            // `#,` escapes the comma so tmux emits it literally — otherwise
            // the bare `,` inside `#{W:...}` is parsed as the active/inactive
            // format separator and no commas appear in the output.
            format: "#{W:#{window_name}#,}",
            storeAs: "tmuxOrderAfterClose"
        )
        TestStep.assertStoredContains(
            key: "tmuxOrderAfterClose",
            substring: "winC,winB,terminal 1,"
        )
        TestStep.macScreenshot(label: "mac-tabreorder-after-close-winA")

        // ── Phase 7: Trailing drop zone — drag past the last tab ─────
        //
        // The new trailing drop zone fills the rest of the bar to the right
        // of the last visible tab so users can drop "past the end". It's a
        // `Color.clear` view in production; we add an AX identifier on it
        // (`tab-trailing-drop-single`) so the test can drag onto it through
        // the same AX path as every other tab. The post-drag tmux order is
        // checked via `display-message` to confirm `syncSubsequences` ran.
        TestStep.log("Phase 7: Drag winC to the trailing drop zone — moves to end")
        TestStep.macDragElement(
            from: .labelContains("tabreorder:0 winC"),
            to: .identifier("tab-trailing-drop-single")
        )
        TestStep.wait(seconds: 3)
        TestStep.tmuxStoreDisplayMessage(
            target: "tabreorder",
            // `#,` escapes the comma so tmux emits it literally — otherwise
            // the bare `,` inside `#{W:...}` is parsed as the active/inactive
            // format separator and no commas appear in the output.
            format: "#{W:#{window_name}#,}",
            storeAs: "tmuxOrderAfterEndDrop"
        )
        TestStep.assertStoredContains(
            key: "tmuxOrderAfterEndDrop",
            substring: "winB,terminal 1,winC,"
        )
        TestStep.macWaitForElement(titled: "tabreorder:0 winB", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:1 terminal 1", timeout: 5)
        TestStep.macWaitForElement(titled: "tabreorder:2 winC", timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-after-trailing-drop")

        // ── Phase 8: Cross-divider drag — terminal into the right pane ─
        //
        // Open a file tab, open the split via its split toggle, then drag a
        // left-side terminal onto the right-side file tab. The terminal's
        // side flips through the unified `toggleSplit` callback and the
        // right pane re-renders to host the terminal. Exercises the
        // regression where dragging a terminal to the right pane left it
        // visible on both panes.
        //
        // Caveat: prior phases reordered tmux, which renumbers the
        // `session:N` IDs that `tabOrder` keys on. After reorder the visual
        // tab strip can show windows in a different sequence than the user
        // expects, and a cross-divider drag may flip the window currently
        // occupying tmux index 0 — not necessarily the user's source. We
        // verify the *effect* (some terminal lands on the right side) via
        // generic `Move terminal to left:` queries instead of asserting a
        // specific window name.
        TestStep.log("Phase 8: Open hello.txt, split it, then drag a terminal across the divider")
        TestStep.macClickButton(titled: "Files")
        TestStep.macWaitForElement(titled: "hello.txt", timeout: 10)
        TestStep.macContextMenuClick(elementTitle: "hello.txt", menuItem: "Open in New Tab")
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)

        // Open split via hello.txt's split toggle.
        TestStep.macClickButton(titled: "Open file tab in split: hello.txt")
        TestStep.macWaitForElement(titled: "Move file tab to left: hello.txt", timeout: 5)
        // Every terminal on the left should now show a "to right" arrow,
        // confirming the unified split-toggle wired up for window tabs too.
        TestStep.macWaitForElementQuery(.labelContains("Move terminal to right:"), timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-split-opened-with-file")

        // Drag a left-side terminal (the one currently at tmux index 0)
        // onto the right-side hello.txt tab. The `adjustSplitSideIfNeeded`
        // path runs the same bookkeeping as clicking the split toggle.
        TestStep.macDragElement(
            from: .labelContains("tabreorder:0"),
            to: .label("Move file tab to left: hello.txt")
        )
        // A terminal arrow now points left — some window lives on the right.
        TestStep.macWaitForElementQuery(.labelContains("Move terminal to left:"), timeout: 5)
        // Settle wait for the split-pane animation; the element appears
        // before the layout finishes transitioning.
        TestStep.wait(seconds: 3)
        // The cross-divider drag may have reassigned `selectedWindow` to a
        // different left-side window than the one we registered with the
        // file browser at the start of this phase (the click on "Files"
        // above only inserted the *then-current* selection into
        // `fileBrowserActiveWindowIds`). Without an explicit click here,
        // the left pane shows the file explorer or a terminal depending on
        // which window the auto-reassignment landed on — non-deterministic
        // (issue regenerated this baseline twice already in #534 / #540).
        // Re-click Files so the current selected window is registered and
        // the screenshot always captures the file-explorer state.
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-tabreorder-terminal-on-right")

        // ── Phase 9: Drag the file explorer onto the right pane ─────
        //
        // The `Files` folder button is also a draggable payload, keyed on a
        // stable `.fileExplorer` identifier (no `tmux:N` instability).
        // Sending it to the right pane should render the file tree there
        // instead of in the left pane — covers the regression where a
        // right-side file-explorer click would also activate the left
        // pane's tree.
        TestStep.log("Phase 9: Drag Files folder button to the right pane")
        TestStep.macDragElement(
            from: .label("Files"),
            to: .label("Move file tab to left: hello.txt")
        )
        TestStep.macWaitForElement(titled: "Move file explorer to left: Files", timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-explorer-on-right")

        // ── Phase 10: Auto-collapse when the left section is empty ─────
        //
        // Move every remaining left-side terminal to the right via its
        // split arrow. Once nothing is left of the divider, the split
        // collapses automatically and the strip flips back to single-pane
        // icons. Verifies the `leftEmpty` branch in
        // `reconcileRightPaneSelection`.
        TestStep.log("Phase 10: Move remaining left terminals to right → split collapses")
        // Click each remaining "Move terminal to right:" arrow on the left
        // pane until none remain. We don't know the specific window names
        // because the ID-stability caveat shuffled them — but tapping the
        // arrow on whichever terminal is currently leftmost works the same
        // way regardless of name.
        TestStep.macCGClickElement(query: .labelContains("Move terminal to right:"))
        TestStep.wait(seconds: 1)
        TestStep.macCGClickElement(query: .labelContains("Move terminal to right:"))
        // Settle wait for the split-collapse layout transition — the AX
        // tree can lag the reconcile briefly after the last terminal
        // moves right, so give the collapse animation room before polling.
        TestStep.wait(seconds: 2)
        // Every "Move *" arrow should be gone; "Open … in split" icons return.
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("Move terminal to left:"),
            timeout: 10
        )
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("Move file tab to left:"),
            timeout: 5
        )
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("Move file explorer to left:"),
            timeout: 5
        )
        TestStep.macWaitForElement(titled: "Open file tab in split: hello.txt", timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-collapsed-from-left-empty")

        // ── Phase 11: Right-side terminal exits → split collapses ─────
        //
        // Open a split with a terminal on the right via its single-mode
        // split toggle, then kill that window from tmux. The pane-state
        // observer prunes the dangling right-side payload and the split
        // collapses without leaving the "No Tab Selected" placeholder
        // visible — covers the regression where an exited right-side
        // terminal kept the empty split alive.
        TestStep.log("Phase 11: Kill the right-side terminal via tmux → split collapses")
        // Click any "Open terminal in split:" arrow to open the split.
        TestStep.macCGClickElement(query: .labelContains("Open terminal in split:"))
        TestStep.macWaitForElementQuery(.labelContains("Move terminal to left:"), timeout: 5)
        TestStep.macScreenshot(label: "mac-tabreorder-split-only-terminal-right")

        // tmux kill-window with a window-name target works regardless of
        // its current index after the prior reorders.
        TestStep.tmuxCommand(arguments: ["kill-window", "-t", "tabreorder:winC"])
        TestStep.macWaitForElementQueryToDisappear(
            .labelContains("Move terminal to left:"),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-tabreorder-after-right-terminal-killed")

        // ── Tear down ────────────────────────────────────────────────
        // Use kill-session so every window in both sessions is cleaned up
        // unconditionally. `exit`-on-pane only closes its own window and
        // would leave the other windows (winB, terminal 1) and the second
        // session running if the scenario aborted mid-flight.
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "tabreorder"])
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "tabreorder-other"])
        TestStep.wait(seconds: 2)
    }
}
