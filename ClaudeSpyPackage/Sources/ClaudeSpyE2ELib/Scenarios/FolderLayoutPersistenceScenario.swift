import Foundation

/// E2E scenario: per-folder workbench layout persistence.
///
/// **Branch:** `feat/folder-layout-persistence` — open file/browser tabs and the
/// split arrangement are persisted per folder (keyed by host + tmux session
/// name, with the folder recorded) so a session restores its workbench, and a
/// new session on a known folder inherits that folder's last-known layout. See
/// `docs/folder-layout-persistence-plan.md`.
///
/// On the E2E tmux socket every session shares one working directory, so two
/// sessions are always "in the same folder" — exactly the condition this feature
/// targets. The scenario proves three things end-to-end:
///
/// 1. **Folder-default clone** — open two file tabs in session `alpha`, then
///    select the sibling session `beta` (same folder, empty) and watch it
///    inherit `alpha`'s tabs. This exercises the live auto-save → store →
///    seed-on-birth pipeline.
/// 2. **Independence after clone** — closing a tab in `beta` does NOT affect
///    `alpha`; the two diverge once seeded.
/// 3. **Restore across an app restart** — terminate the app and relaunch; the
///    already-running `alpha` session restores its own saved layout from disk
///    (the cold-launch requirement). tmux survives the restart, and the layout
///    store lives under the per-instance `--gallager-state-root`, so the record
///    persists across the relaunch.
public enum FolderLayoutPersistenceScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Folder Layout Persistence",
        tags: ["file-browser", "layout-persistence", "macos-only"]
    ) {
        // ── Setup: two sessions sharing the tmux server's cwd ────────
        TestStep.log("Setup: create two tmux sessions (same folder) and launch the app")
        TestStep.tmuxCreateSession(name: "alpha", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "alpha:0")
        TestStep.tmuxCreateSession(name: "beta", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "beta:0")

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        // Re-pin the sidebar after the resize: `.balanced` NavigationSplitView
        // reflows column widths otherwise and the screenshots flake.
        TestStep.macSetSidebarWidth(250)

        // ── 1. Open two file tabs in `alpha` ─────────────────────────
        TestStep.log("Phase 1: open hello.txt and README.md as file tabs in alpha")
        TestStep.macWaitForElement(titled: "alpha", timeout: 5)
        TestStep.macClickButton(titled: "alpha")
        TestStep.macClickButton(titled: "Files")
        TestStep.macWaitForElement(titled: "README.md", timeout: 10)

        TestStep.macContextMenuClick(elementTitle: "hello.txt", menuItem: "Open in New Tab")
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)
        // Switch back to the tree so the next right-click hits the row, not the
        // just-opened tab's label.
        TestStep.macClickButton(titled: "Files")
        TestStep.macContextMenuClick(elementTitle: "README.md", menuItem: "Open in New Tab")
        TestStep.macWaitForElement(titled: "File tab: README.md", timeout: 5)
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.macScreenshot(label: "mac-alpha-two-tabs")

        // ── 2. Folder-default clone onto `beta` ──────────────────────
        TestStep.log("Phase 2: select beta (same folder, empty) — it inherits alpha's tabs")
        // Auto-save runs on a 2s cadence; give it a beat to persist alpha's
        // layout before beta's seed-on-birth reads the folder default.
        TestStep.wait(seconds: 3)
        TestStep.macClickButton(titled: "beta")
        // beta started empty; these tabs only appear if the folder-default seed
        // fired. This is the headline assertion.
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 10)
        TestStep.macWaitForElement(titled: "File tab: README.md", timeout: 5)
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.macScreenshot(label: "mac-beta-cloned-from-folder")

        // ── 3. Independence after clone ──────────────────────────────
        TestStep.log("Phase 3: close README.md in beta; alpha keeps both tabs (they diverge)")
        TestStep.macClickButton(titled: "File tab: README.md")
        TestStep.macClickButton(titled: "Close file tab: README.md")
        TestStep.macWaitForElementToDisappear(titled: "File tab: README.md", timeout: 5)

        TestStep.macClickButton(titled: "alpha")
        // alpha is unaffected by beta's close — README.md is still open here.
        TestStep.macWaitForElement(titled: "File tab: README.md", timeout: 5)
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.macScreenshot(label: "mac-alpha-unchanged-after-beta-diverged")

        // ── 4. Restore across an app restart (cold launch) ───────────
        TestStep.log("Phase 4: restart the app; the running alpha session restores its layout from disk")
        // Let the latest auto-save land on disk before quitting (the loss window
        // is one 2s cadence; wait covers it).
        TestStep.wait(seconds: 3)
        TestStep.terminateMacApp()
        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)
        Shortcut.openPanesWindow()
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(250)

        TestStep.macWaitForElement(titled: "alpha", timeout: 10)
        TestStep.macClickButton(titled: "alpha")
        // Restored from the on-disk record keyed by alpha's tmux session name.
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 10)
        TestStep.macWaitForElement(titled: "File tab: README.md", timeout: 5)
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.macScreenshot(label: "mac-alpha-restored-after-restart")

        // ── Tear down ────────────────────────────────────────────────
        Shortcut.tmuxRunCommand(target: "alpha:0", command: "exit")
        Shortcut.tmuxRunCommand(target: "beta:0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
