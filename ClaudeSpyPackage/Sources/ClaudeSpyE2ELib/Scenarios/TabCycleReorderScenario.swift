import Foundation

/// E2E scenario: Cmd-Shift-[ / Cmd-Shift-] follow the *reordered* tab strip
/// across tab kinds (issue #566).
///
/// The existing `TabReorderScenario` only cycles between terminal windows,
/// which are all the same kind — so its keyboard phase stayed correct even
/// while #566 was live. The bug only surfaces when a *different* kind of tab
/// (a file tab or a browser tab) is dragged to sit *between* two terminals:
/// the keyboard handler built the strip in a fixed kind-grouped order
/// (windows → file explorer → file tabs → browser tabs) and so cycled in the
/// original layout instead of the one on screen.
///
/// This scenario reproduces that: open a file tab, drag it between two
/// terminals, then press Cmd-Shift-]. Before the fix, the shortcut jumps from
/// `winA` straight to `winB` (skipping the interleaved file tab). After the
/// fix it lands on the file tab, matching the visible order. A file tab is
/// used instead of a browser tab so the proof needs no network / WKWebView —
/// the underlying ordering logic is kind-agnostic and unit-tested for both.
public enum TabCycleReorderScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Tab Cycle Reorder",
        tags: ["tabs", "reorder", "macos-only"]
    ) {
        // ── Setup: one session, two terminal windows ─────────────────
        TestStep.log("Setup: tmux session with winA and winB")
        TestStep.tmuxCreateSession(name: "tabcycle", width: 100, height: 30)
        TestStep.tmuxCommand(arguments: ["rename-window", "-t", "tabcycle:0", "winA"])
        TestStep.tmuxCommand(arguments: ["new-window", "-t", "tabcycle", "-n", "winB"])
        // `new-window` inherits the tmux server's cwd (the e2e checkout dir),
        // which would leak into winB's prompt and flake the screenshots. Reset
        // to $HOME so the captured prompt is stable regardless of where the
        // suite runs. winA was pinned to $HOME by `new-session -c`.
        Shortcut.tmuxRunCommand(target: "tabcycle:winB", command: "cd; clear")
        TestStep.tmuxCommand(arguments: ["select-window", "-t", "tabcycle:0"])
        // Stable session title so the window/sidebar labels don't fall back to
        // the working-directory path (which varies by checkout folder).
        TestStep.tmuxCommand(arguments: ["set-option", "-t", "=tabcycle:", "@gallager-description", "Tab Cycle"])

        // ── Launch app and select the session ────────────────────────
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_300, height: 700)
        // Re-pin the sidebar after the resize: `.balanced` NavigationSplitView
        // reflows column widths on resize, so without this the sidebar width
        // is non-deterministic across runs and the screenshots flake.
        TestStep.macSetSidebarWidth(250)

        TestStep.macWaitForElement(titled: "tabcycle", timeout: 10)
        TestStep.macClickButton(titled: "tabcycle")
        TestStep.macWaitForElement(titled: "tabcycle:0 winA", timeout: 10)
        TestStep.macWaitForElement(titled: "tabcycle:1 winB", timeout: 10)

        // ── Open a file tab (a non-window tab kind) ──────────────────
        TestStep.log("Open hello.txt in a new tab so the strip has a non-window kind")
        TestStep.macClickButton(titled: "Files")
        TestStep.macWaitForElement(titled: "hello.txt", timeout: 10)
        TestStep.macContextMenuClick(elementTitle: "hello.txt", menuItem: "Open in New Tab")
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)
        // Default layout now reads: winA · winB · Files · hello.txt.
        TestStep.macScreenshot(label: "mac-tabcycle-default-order")

        // ── Drag the file tab to sit between winA and winB ───────────
        TestStep.log("Drag hello.txt onto winB so it lands between winA and winB")
        TestStep.macDragElement(
            from: .label("File tab: hello.txt"),
            to: .labelContains("tabcycle:1 winB")
        )
        // Settle wait for the reorder + AX tree to catch up after the drag.
        TestStep.wait(seconds: 3)

        // ── Cmd-Shift-] cycles in the *reordered* order ──────────────
        TestStep.log("From winA, Cmd-Shift-] must land on the interleaved file tab — not winB")
        // Anchor on winA (clearing the file-tab selection from the drag). The
        // screenshot captures the reordered strip (winA · hello.txt · winB ·
        // Files) with winA's terminal showing — the starting point for the
        // keyboard step, and visually distinct from the file-tab shot below.
        TestStep.macClickButton(titled: "tabcycle:0 winA")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-tabcycle-after-drag-winA-selected")

        // The regression assertion: next tab is hello.txt (its new visual
        // slot), proving keyboard cycling follows the drag-reordered strip.
        // Before the #566 fix this selected winB instead, skipping the file
        // tab — so this step would fail and the file content below would
        // instead show winB's terminal.
        TestStep.macPressKey(.character("]"), modifiers: [.command, .shift])
        TestStep.macWaitForElementQuery(
            .allOf([.label("File tab: hello.txt"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macScreenshot(label: "mac-tabcycle-next-lands-on-file-tab")

        // One more step forward reaches winB (the tab the buggy order would
        // have jumped to first).
        TestStep.macPressKey(.character("]"), modifiers: [.command, .shift])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabcycle:1 winB"), .valueContains("selected")]),
            timeout: 5
        )

        // ── Cmd-Shift-[ walks back through the same order ────────────
        TestStep.log("Cmd-Shift-[ steps back winB → hello.txt → winA")
        TestStep.macPressKey(.character("["), modifiers: [.command, .shift])
        TestStep.macWaitForElementQuery(
            .allOf([.label("File tab: hello.txt"), .valueContains("selected")]),
            timeout: 5
        )
        TestStep.macPressKey(.character("["), modifiers: [.command, .shift])
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("tabcycle:0 winA"), .valueContains("selected")]),
            timeout: 5
        )

        // ── Tear down ────────────────────────────────────────────────
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "tabcycle"])
        TestStep.wait(seconds: 2)
    }
}
