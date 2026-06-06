import Foundation

/// E2E scenario: Git tab file actions (right-click menu)
///
/// Proves the GitWorkbench PR #2 hooks are wired into ClaudeSpy's Git tab:
/// right-clicking a Changes-tab file row shows the *same* native context menu as
/// the File Explorer, and the store's `repositoryURL` makes that menu act on an
/// absolute file URL.
///
/// 1. Activate the Git tab (mock provider: repo "aurora-cli", changed file
///    "package.json").
/// 2. Right-click "package.json" and pick "Open in Editor → Fake Editor". This
///    succeeds only if the CGEvent right-click reaches GitWorkbench's row
///    mouse-catcher, our `onChangesRightClick` pops up the shared
///    `stableContextMenu`, and the callback receives a usable absolute URL.
/// 3. Assert the fake editor's log records the file's *absolute* path — reusing
///    the `EditorClient.fakeScript` harness from `OpenInEditorScenario` (the
///    macOS app is always launched with `--fake-editor-script` in E2E mode,
///    registering "Fake Editor" / "Fake Editor 2"). A leading slash before the
///    filename is the proof that `repositoryURL` resolution ran.
///
/// Double-click → `NSWorkspace.open` is intentionally *not* asserted here: it
/// hits a real system service against the mock fixture's non-existent path —
/// the same reason `OpenInEditorScenario` asserts only the "Open in Editor"
/// item and not "Open" / "Show in Finder". The double-click wiring is a
/// one-liner mirroring the PR's documented example, covered by code review.
public enum GitTabFileActionsScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Git Tab File Actions",
        tags: ["git", "git-browser", "editors", "file-browser", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        TestStep.log("Setup: create tmux session and launch macOS app")
        // Session name avoids the substring "git": the AX element queries use
        // case-insensitive `contains`, so a "git…" session would collide with
        // the `macClickButton(titled: "Git")` that activates the Git tab.
        TestStep.tmuxCreateSession(name: "repoactions", width: 160, height: 50)
        Shortcut.tmuxRunCommand(target: "repoactions:0.0", command: "echo '=== GIT FILE ACTIONS TEST ==='")

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        // Re-pin the sidebar after the resize: `.balanced` NavigationSplitView
        // reflows column widths on resize, so without this the screenshots flake.
        TestStep.macSetSidebarWidth(250)

        TestStep.macWaitForElement(titled: "repoactions", timeout: 5)
        TestStep.macClickButton(titled: "repoactions")
        TestStep.wait(seconds: 3)

        // ── Phase 1: Activate the Git tab — Changes view ─────────
        TestStep.log("Phase 1: Activate the Git tab and wait for the mock Changes view")
        TestStep.macClickButton(titled: "Git")
        TestStep.macWaitForElement(titled: "aurora-cli", timeout: 10)
        TestStep.macWaitForElement(titled: "package.json", timeout: 5)
        TestStep.macScreenshot(label: "mac-git-changes-ready")

        // ── Phase 2: Right-click → Open in Editor → Fake Editor ──
        //
        // The same shared `FileContextMenu` the File Explorer uses, now popped up
        // from GitWorkbench's `onChangesRightClick` hook. Picking the fake editor
        // launches our Python script with the file path; the log under `$TMPDIR`
        // then contains the absolute path to the changed file.
        TestStep.log("Phase 2: right-click a changed file → 'Open in Editor → Fake Editor'")
        // Fresh log so the assertion can only pass if THIS dispatch runs.
        TestStep.removeFile(path: "${fakeEditorLogPath}")
        TestStep.macContextSubmenuClick(
            elementTitle: "package.json",
            parentMenuItem: "Open in Editor",
            submenuItem: "Fake Editor"
        )
        // The fake editor appends the path it was handed once it launches; poll
        // rather than sleep so Python spin-up jitter doesn't flake the run.
        TestStep.waitForFileContains(
            path: "${fakeEditorLogPath}",
            substring: "package.json",
            storeAs: "gitMenuLog",
            timeout: 10
        )
        // A leading slash before the filename proves the callback received an
        // absolute URL (the `repositoryURL` plumbing), not a bare relative path.
        TestStep.assertStoredContains(key: "gitMenuLog", substring: "/package.json")
        TestStep.macScreenshot(label: "mac-git-menu-fake-editor-launched")

        // Tear down.
        Shortcut.tmuxRunCommand(target: "repoactions:0.0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
