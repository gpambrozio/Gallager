import Foundation

/// E2E scenario: Git Browser tab (issue #258)
///
/// Exercises the new Git tab that embeds the `GitWorkbench` component to the
/// right of the file-explorer tab:
/// 1. Activating the Git tab shows the GitWorkbench Changes view backed by the
///    stable mock provider (repo "aurora-cli", branch "feat/auto-sync", the
///    fixture's changed files).
/// 0. The repo starts clean (no badge). Introducing changes (`setGitMockChanges`)
///    makes a changed-file-count badge appear on the Git tab button — read live
///    from the eagerly-loaded session store's summary — while the terminal, not
///    the Git tab, is still the active view (issue #573).
/// 2. Selecting a changed file loads its diff.
/// 3. Switching the workspace to History shows the fixture commit list.
/// 4. The Git tab's state is retained across a tab round-trip: after switching to
///    the terminal and back, the workbench is still on the History view it was
///    left on (a freshly-created store would default back to Changes).
/// 5. The Git tab can be moved into the split-view right pane and back, exactly
///    like the file-explorer tab.
/// 6. The Git tab's state also survives a full session switch: selecting a
///    different session in the sidebar and returning restores the History view
///    (the per-session store is keyed by session name, not recreated).
///
/// The provider is the deterministic `MockGitProvider` (wired in
/// `ClaudeSpyServerApp` under `--e2e-test` via `GitWorkbenchProviderClient.mock`,
/// zero artificial latency) so every screenshot shows the same fixture data.
public enum GitBrowserScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Git Browser",
        tags: ["git", "git-browser", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        TestStep.log("Setup: Create tmux session and launch macOS app")
        // Session name avoids the substring "git": the AX element queries use
        // case-insensitive `contains`, so a "git…" session would collide with
        // the `macClickButton(titled: "Git")` that activates the Git tab.
        TestStep.tmuxCreateSession(name: "repobrowse", width: 160, height: 50)
        Shortcut.tmuxRunCommand(target: "repobrowse:0.0", command: "echo '=== REPO BROWSER TEST ==='")

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        // Re-pin the sidebar after the resize: `.balanced` NavigationSplitView
        // reflows column widths on resize, so without this the sidebar width is
        // non-deterministic across runs and the screenshots flake.
        TestStep.macSetSidebarWidth(250)

        // Select session in the sidebar.
        TestStep.macWaitForElement(titled: "repobrowse", timeout: 5)
        TestStep.macClickButton(titled: "repobrowse")
        TestStep.wait(seconds: 3)

        // ── Phase 0: Clean repo → no badge; add changes → badge on load ──
        //
        // The displayed session's git status loads eagerly (issue #573), so the
        // Git tab button reflects the repo without the tab being opened. The mock
        // starts clean, so there's no badge here.
        TestStep.log("Phase 0: Clean repo shows no changed-file badge")
        TestStep.macScreenshot(label: "mac-git-terminal-baseline")

        // Introduce changes: the eagerly-loaded store picks them up via the
        // provider's change stream, and a "7 changed files" badge appears on the
        // Git tab button while the terminal — not the Git tab — is still showing.
        TestStep.log("Phase 0: Introduce changes → badge appears on the terminal view")
        TestStep.setGitMockChanges(true)
        TestStep.macWaitForElementQuery(.anyTextMatches("7 changed files"), timeout: 15)
        TestStep.macScreenshot(label: "mac-git-tab-badge")

        // ── Phase 1: Activate the Git tab — Changes view ─────────
        TestStep.log("Phase 1: Activate the Git tab and verify the mock Changes view")
        // Click the Git tab (branch icon, accessibilityLabel: "Git").
        TestStep.macClickButton(titled: "Git")

        // The mock workbench loads: repo name, current branch, and changed files
        // all come from the stable fixtures.
        TestStep.macWaitForElement(titled: "aurora-cli", timeout: 10)
        TestStep.macWaitForElementQuery(.anyTextMatches("feat/auto-sync"), timeout: 5)
        TestStep.macWaitForElement(titled: "package.json", timeout: 5)
        TestStep.macScreenshot(label: "mac-git-changes-view")

        // ── Phase 2: Select a changed file → diff loads ──────────
        TestStep.log("Phase 2: Selecting a changed file loads its diff")
        TestStep.macCGClick(titled: "package.json")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-git-diff-selected")

        // ── Phase 3: Switch to the History workspace view ────────
        TestStep.log("Phase 3: Switch to History and verify the fixture commits")
        TestStep.macCGClick(titled: "History")
        // The newest fixture commit summary only renders in the History view.
        TestStep.macWaitForElementQuery(.anyTextMatches("Add structured Logger"), timeout: 5)
        TestStep.macScreenshot(label: "mac-git-history-view")

        // ── Phase 4: State persists across a tab round-trip ──────
        //
        // The GitWorkbench store is retained per session in MainView, so leaving
        // the Git tab and returning must restore the History view (a fresh store
        // would default back to Changes). This is the regression guard for the
        // "state should be saved and restored" requirement.
        TestStep.log("Phase 4: Git state persists across a terminal tab round-trip")
        TestStep.macClickButton(titled: "repobrowse:0")
        TestStep.wait(seconds: 2)
        // The changed-file badge persists on the Git tab button while the terminal
        // is the visible view; the count is surfaced on the button's accessibility
        // value (issue #573).
        TestStep.macWaitForElementQuery(.anyTextMatches("7 changed files"), timeout: 10)
        TestStep.macScreenshot(label: "mac-git-terminal-restored")

        TestStep.macClickButton(titled: "Git")
        // Still on History — the commit list is present without re-selecting it.
        TestStep.macWaitForElementQuery(.anyTextMatches("Add structured Logger"), timeout: 5)
        TestStep.macScreenshot(label: "mac-git-state-preserved")

        // ── Phase 5: Move the Git tab into a split view ──────────
        TestStep.log("Phase 5: Move the Git tab to the split-view right pane and back")
        TestStep.macClickButton(titled: "Open git in split: Git")
        // The Git tab now lives on the right; its toggle flips to "move to left".
        TestStep.macWaitForElement(titled: "Move git to left: Git", timeout: 5)
        // The workbench content is still rendered, now in the right pane.
        TestStep.macWaitForElement(titled: "aurora-cli", timeout: 5)
        TestStep.macScreenshot(label: "mac-git-split-right")

        // Move it back to the left — the split collapses (Git was the only
        // right-side tab) and the single-pane split icon returns.
        TestStep.macClickButton(titled: "Move git to left: Git")
        TestStep.macWaitForElement(titled: "Open git in split: Git", timeout: 5)
        TestStep.macWaitForElement(titled: "aurora-cli", timeout: 5)
        TestStep.macScreenshot(label: "mac-git-split-collapsed")

        // ── Phase 6: State persists across a SESSION switch ──────
        //
        // The GitWorkbench store is keyed by session name and the Git-active
        // flag by window id, so selecting a *different* session in the sidebar
        // and returning must also restore the History view — without even
        // re-clicking the Git tab. Phase 4 only covered a same-session tab
        // round-trip; this guards retention across a full session switch.
        TestStep.log("Phase 6: Git state persists across a session switch")

        // A second session to switch to. Created here (not in setup) so the
        // earlier phases' screenshots aren't disturbed by an extra sidebar row.
        // The name avoids the substring "git" for the same reason as above.
        TestStep.tmuxCreateSession(name: "otherproj", width: 160, height: 50)
        Shortcut.tmuxRunCommand(target: "otherproj:0.0", command: "echo '=== OTHER PROJECT ==='")

        // Select the other session — its terminal replaces the Git view.
        // A freshly-created tmux session only surfaces in the sidebar on the
        // next periodic refresh (~5s), so allow two cycles to avoid racing it.
        TestStep.macWaitForElement(titled: "otherproj", timeout: 12)
        TestStep.macClickButton(titled: "otherproj")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-git-other-session")

        // Return to repobrowse: the Git tab is still active and still on
        // History (the commit list renders with no re-selection), proving the
        // per-session store survived the session switch.
        TestStep.macClickButton(titled: "repobrowse")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("Add structured Logger"), timeout: 5)
        TestStep.macScreenshot(label: "mac-git-session-preserved")

        // ── Tear down ────────────────────────────────────────────
        Shortcut.tmuxRunCommand(target: "repobrowse:0.0", command: "exit")
        Shortcut.tmuxRunCommand(target: "otherproj:0.0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
