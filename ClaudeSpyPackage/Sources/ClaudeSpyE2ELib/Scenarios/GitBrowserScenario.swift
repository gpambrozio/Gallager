import Foundation

/// E2E scenario: Git Browser tab (issue #258)
///
/// Exercises the new Git tab that embeds the `GitWorkbench` component to the
/// right of the file-explorer tab:
/// 1. Activating the Git tab shows the GitWorkbench Changes view backed by the
///    stable mock provider (repo "aurora-cli", branch "feat/auto-sync", the
///    fixture's changed files).
/// 2. Selecting a changed file loads its diff.
/// 3. Switching the workspace to History shows the fixture commit list.
/// 4. The Git tab's state is retained across a tab round-trip: after switching to
///    the terminal and back, the workbench is still on the History view it was
///    left on (a freshly-created store would default back to Changes).
/// 5. The Git tab can be moved into the split-view right pane and back, exactly
///    like the file-explorer tab.
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

        // ── Phase 1: Activate the Git tab — Changes view ─────────
        TestStep.log("Phase 1: Activate the Git tab and verify the mock Changes view")
        TestStep.macScreenshot(label: "mac-git-terminal-baseline")

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

        // ── Tear down ────────────────────────────────────────────
        Shortcut.tmuxRunCommand(target: "repobrowse:0.0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
