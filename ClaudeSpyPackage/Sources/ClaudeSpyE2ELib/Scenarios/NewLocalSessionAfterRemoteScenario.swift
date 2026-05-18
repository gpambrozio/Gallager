import Foundation

/// E2E scenario: Creating a new local session must select it, even when a
/// remote session was the last thing the user interacted with.
///
/// Regression test for the bug where `createNewSession` set `selectedWindow`
/// without clearing `selectedRemoteSession` / `selectedRemoteWindowId`.
/// Two reproductions:
///   1. While a remote session is selected, click "+" in the Local section
///      and create a new terminal — the new terminal must take selection
///      (detail pane swaps to the new local terminal).
///   2. After the underlying remote session is killed (its sidebar row
///      disappears but stale remote-selection state still lingers locally),
///      click "+" in the Local section — the new terminal must again
///      take selection rather than leaving the detail pane stuck on a
///      "no session selected" placeholder.
public enum NewLocalSessionAfterRemoteScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "New Local Session After Remote",
        tags: ["sessions", "sidebar", "remote", "macos-only"]
    ) {
        // 1. Pair host (instance 0) and viewer (instance 1). The viewer's
        //    sidebar will then show the host's sessions in a Remote section
        //    while its own (empty at first) Local section sits above.
        Shortcut.twoMacPairing

        // 2. Create a tmux session on the host so the viewer has a remote
        //    session to interact with. Print a marker string that we can
        //    later look for in the detail pane to determine whether the
        //    remote is the currently-rendered terminal.
        TestStep.tmuxCreateSession(name: "remote-marker", width: 80, height: 24)
        Shortcut.tmuxClearAndSetPrompt(target: "remote-marker:0")
        Shortcut.tmuxRunCommand(target: "remote-marker:0.0", command: "echo 'REMOTE_MARKER_CONTENT'")

        // 3. Bring up the viewer's panes window and wait for the remote
        //    session to appear in the Remote section.
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macResizeWindow(width: 1_200, height: 700, instance: 1)
        TestStep.macWaitForElement(titled: "remote-marker", timeout: 15, instance: 1)

        // ── Phase 1: remote-selected → new local terminal ──────────
        TestStep.log("Phase 1: select remote session, then create a new local terminal")
        TestStep.macClickButton(titled: "remote-marker", instance: 1)

        // The detail pane renders the remote terminal — its marker should
        // be visible in the accessibility value of the rendered terminal.
        TestStep.macWaitForElementQuery(
            .valueContains("REMOTE_MARKER_CONTENT"),
            timeout: 10,
            instance: 1
        )
        // Re-pin window size: rendering the remote terminal auto-grows the
        // panes window, so screenshots need a deterministic baseline size.
        TestStep.macScreenshot(label: "viewer-remote-selected", instance: 1)

        // Click the Local section's "+". Uses CGEvent click rather than
        // AXPress because AXPress on a sidebar-section-header Button with a
        // popover modifier leaves the section's content lazy-row pipeline in
        // a broken state — `ForEach`'s row closures never get called,
        // leaving the section visually empty even though the data is right.
        // A real mouse click goes through AppKit/SwiftUI's gesture system
        // normally and works fine.
        TestStep.macCGClickElement(
            query: .identifier("new-session-local"),
            pointInRect: { CGPoint(x: $0.maxX - 4, y: $0.midY) },
            instance: 1
        )
        TestStep.macWaitForElement(titled: "New Terminal", timeout: 5, instance: 1)
        TestStep.macClickButton(titled: "New Terminal", instance: 1)

        // The new local terminal session must now be selected: the new
        // "terminal" row appears AND the remote terminal's content is no
        // longer rendered in the detail pane (the original bug left the
        // remote terminal visible because `selectedRemoteSession` was
        // never cleared, so the detail-pane router kept routing to the
        // remote view).
        TestStep.macWaitForElement(titled: "terminal", timeout: 10, instance: 1)
        TestStep.macWaitForElementQueryToDisappear(
            .valueContains("REMOTE_MARKER_CONTENT"),
            timeout: 10,
            instance: 1
        )
        TestStep.macScreenshot(label: "viewer-local-selected-after-remote", instance: 1)

        // ── Phase 2: remote killed → new local terminal ────────────
        TestStep.log("Phase 2: re-select remote, kill it on the host, then create another local")

        // Re-select the remote so `selectedRemoteSession` is set again
        // (sessionButton's onSelect for the remote row clears
        // `selectedWindow`). This rebuilds the bug's precondition without
        // having to first close the Phase 1 local session.
        TestStep.macClickButton(titled: "remote-marker", instance: 1)
        TestStep.macWaitForElementQuery(
            .valueContains("REMOTE_MARKER_CONTENT"),
            timeout: 10,
            instance: 1
        )

        // Kill the remote session on the host. The viewer's sidebar row
        // disappears, but the viewer's `selectedRemoteSession` state still
        // points at the now-dead session — the second repro path described
        // in the bug report. With the remote gone, `selectedRemoteWindow`
        // computes to nil, so the detail-pane router falls through to its
        // "Loading Session" placeholder (selectedRemoteSession non-nil,
        // remoteWindow nil, viewer still connected — see MainView's
        // `detailContent` branches).
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "remote-marker"])
        TestStep.macWaitForElementToDisappear(titled: "remote-marker", timeout: 15, instance: 1)
        TestStep.macWaitForElement(titled: "Loading Session", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-loading-session-after-remote-kill", instance: 1)

        // Create a new local terminal. With the fix: `selectedRemoteSession`
        // is cleared and the detail-pane router falls into its
        // `selectedWindow` branch, rendering the new local terminal.
        // With the regression: stale `selectedRemoteSession` keeps the
        // router on the "Loading Session" placeholder forever.
        // Uses CGEvent click at the right edge of the local section
        // header (see Phase 1 comment for why AXPress isn't viable here).
        TestStep.macCGClickElement(
            query: .identifier("new-session-local"),
            pointInRect: { CGPoint(x: $0.maxX - 4, y: $0.midY) },
            instance: 1
        )
        TestStep.macWaitForElement(titled: "New Terminal", timeout: 5, instance: 1)
        TestStep.macClickButton(titled: "New Terminal", instance: 1)

        // The "Loading Session" placeholder must be gone — that's the
        // load-bearing regression check. A regression would leave it stuck.
        TestStep.macWaitForElementToDisappear(titled: "Loading Session", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-local-selected-after-remote-killed", instance: 1)
    }
}
