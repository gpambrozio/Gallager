import Foundation

/// E2E scenario: Rename tmux windows from host and from a paired Mac viewer.
///
/// Verifies that:
/// 1. Tabs show the tmux window name (not the running command).
/// 2. Right-clicking a tab on the host opens a "Rename Window" context menu
///    item; saving a new name updates both the host and the paired viewer.
/// 3. Right-clicking a tab on the viewer opens the same "Rename Window" item;
///    saving relays the rename back through the host and both ends update.
/// 4. Creating a new window via the "+" button gives it a `"terminal N"` name
///    picked by counting existing `terminal N` names in the session.
public enum WindowRenameScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Window Rename",
        tags: ["tabs", "rename", "macos-only"]
    ) {
        // ── Phase 1: Pair two Mac apps ─────────────────────────
        Shortcut.twoMacPairing

        // Close Settings windows so `openPanesWindow` targets the Panes window
        // for move/resize (AX's "first window" can otherwise pick Settings).
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        TestStep.wait(seconds: 1)

        // ── Phase 2: Create session with two named windows ─────
        TestStep.log("Phase 2: Create session with two named windows")
        TestStep.tmuxCreateSession(name: "e2e-rename", width: 80, height: 24)

        // Name the first window explicitly so tabs have deterministic labels.
        Shortcut.tmuxRunCommand(target: "e2e-rename:0.0", command: "tmux rename-window -t e2e-rename:0 'win0'")
        TestStep.wait(seconds: 1)

        Shortcut.tmuxRunCommand(target: "e2e-rename:0.0", command: "tmux new-window -t e2e-rename")
        TestStep.wait(seconds: 2)
        Shortcut.tmuxRunCommand(target: "e2e-rename:1.0", command: "tmux rename-window -t e2e-rename:1 'win1'")

        // Switch tmux back to window 0 so the sidebar click opens it.
        Shortcut.tmuxRunCommand(target: "e2e-rename:1.0", command: "tmux select-window -t e2e-rename:0")
        TestStep.wait(seconds: 3)

        // ── Phase 3: Open host panes window and verify tab labels ──
        TestStep.log("Phase 3: Open host panes window — tabs should display window names")
        Shortcut.openPanesWindow()

        TestStep.macWaitForElement(titled: "e2e-rename", timeout: 10)
        TestStep.macClickButton(titled: "e2e-rename")
        TestStep.wait(seconds: 3)

        // Tabs show the tmux window name as their title (not the shell/command name).
        TestStep.macWaitForElement(titled: "win0", timeout: 10)
        TestStep.macWaitForElement(titled: "win1", timeout: 10)
        TestStep.macScreenshot(label: "host-initial-tabs")

        // ── Phase 4: Open viewer panes window and verify tab labels ──
        TestStep.log("Phase 4: Open viewer panes window — tabs mirror host labels")
        Shortcut.openPanesWindow(instance: 1)

        TestStep.macWaitForElement(titled: "e2e-rename", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "e2e-rename", instance: 1)
        TestStep.wait(seconds: 3)

        TestStep.macWaitForElement(titled: "win0", timeout: 10, instance: 1)
        TestStep.macWaitForElement(titled: "win1", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-initial-tabs", instance: 1)

        // ── Phase 5: Host renames window 0 via context menu ────
        TestStep.log("Phase 5: Host right-clicks tab and renames window 0")
        // The tab's accessibility label is "{windowId} {windowName}" (e.g.
        // "e2e-rename:0 win0"); matching by the windowId prefix via `contains`
        // is enough and keeps this step independent of the current name.
        TestStep.macContextMenuClick(elementTitle: "e2e-rename:0", menuItem: "Rename Window")
        TestStep.macWaitForElement(titled: "Rename Window", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macPressTab()
        TestStep.macSelectAll()
        TestStep.macType(text: "HostRenamed", pressReturn: false)
        TestStep.macScreenshot(label: "host-rename-alert-typed")
        TestStep.macClickButton(titled: "Save")
        TestStep.wait(seconds: 2)

        // Host tab updates to the new name.
        TestStep.macWaitForElement(titled: "HostRenamed", timeout: 10)
        TestStep.macScreenshot(label: "host-after-host-rename")

        // Viewer reflects the host's rename.
        TestStep.macWaitForElement(titled: "HostRenamed", timeout: 15, instance: 1)
        TestStep.macScreenshot(label: "viewer-after-host-rename", instance: 1)

        // ── Phase 6: Viewer renames window 1 via context menu ──
        TestStep.log("Phase 6: Viewer right-clicks tab and renames window 1")
        TestStep.macContextMenuClick(elementTitle: "e2e-rename:1", menuItem: "Rename Window", instance: 1)
        TestStep.macWaitForElement(titled: "Rename Window", timeout: 5, instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macPressTab(instance: 1)
        TestStep.macSelectAll(instance: 1)
        TestStep.macType(text: "ViewerRenamed", pressReturn: false, instance: 1)
        TestStep.macScreenshot(label: "viewer-rename-alert-typed", instance: 1)
        TestStep.macClickButton(titled: "Save", instance: 1)
        TestStep.wait(seconds: 2)

        // Viewer tab updates to the new name.
        TestStep.macWaitForElement(titled: "ViewerRenamed", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-after-viewer-rename", instance: 1)

        // Host reflects the viewer's rename (relayed through the host's command handler).
        TestStep.macWaitForElement(titled: "ViewerRenamed", timeout: 15)
        TestStep.macScreenshot(label: "host-after-viewer-rename")

        // ── Phase 7: New windows get "terminal N" names via the + button ──
        TestStep.log("Phase 7: Create new window via + button — expect 'terminal 1' name")
        TestStep.macClickButton(titled: "New Window", instance: 1)
        TestStep.wait(seconds: 5)

        // No existing `terminal N` names in the session yet, so the next one is `terminal 1`.
        TestStep.macWaitForElement(titled: "terminal 1", timeout: 15, instance: 1)
        TestStep.macWaitForElement(titled: "terminal 1", timeout: 15)
        TestStep.macScreenshot(label: "host-new-window-terminal-1")
        TestStep.macScreenshot(label: "viewer-new-window-terminal-1", instance: 1)
    }
}
