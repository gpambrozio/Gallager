import Foundation

/// E2E scenario: File Browser
///
/// Exercises all file browser features added in issue #257, #289, #398, and #429:
/// 1. Tab activation/deactivation and initial empty state
/// 2. Text, markdown, HTML, image, PDF, video, and unsupported file viewers
/// 3. Lazy-loading folder expansion at multiple depth levels
/// 4. Context menu with clipboard assertions (Copy Path, Copy Relative Path)
/// 5. State persistence across tab toggle (expansion, selection, sidebar width)
/// 6. File search with matching results, no results, and persistence across tab switch
/// 7. State isolation on window switch (file browser tree does not leak to other windows)
/// 8. Open in New Tab: context menu opens the file in a tab next to the file browser,
///    supports switching/closing tabs, and keeps the tab open with a strikethrough
///    filename when the underlying file is deleted externally.
/// 9. While a file tab is selected, the underlying tmux window tab is NOT also
///    rendered as selected (regression guard for PR #399 issue 1).
/// 10. File tabs are session-scoped and persist when switching between tmux
///     windows in the same session (regression guard for PR #399 issue 2).
/// 11. Right-clicking an open file tab shows the same context menu as the file
///     navigator (issue #415) — `Copy Path` and `Copy Relative Path` round-trip
///     through the clipboard prove the shared menu component is wired up.
/// 12. "Show in File Explorer" on a file tab routes the user back to the tree,
///     auto-expanding any collapsed ancestor folders and selecting the file.
/// 13. A long file's scroll position is preserved when switching to another
///     window or session and returning (issue #429). The markdown, plain-text,
///     PDF, and HTML viewers each have their own SwiftUI implementation, and
///     the detail pane (tree-selected file) and open-file-tab paths use
///     separate scroll-offset stores, so all four viewer types are exercised
///     through both surfaces.
/// 14. The file browser tree, selection, expansions, search query, and per-path
///     scroll position are shared across windows in the same tmux session
///     (commit 90f1d8f). Switching to a sibling window's Files tab shows the
///     same state without rebuilding it.
///
/// Regression guards:
/// - Nested NavigationSplitView layout gap (ee55599)
/// - SwiftUI VideoPlayer crash (d278865)
/// - Session switch state leak (517c7db)
/// - Markdown rendering (d278865 → 1163e87)
/// - Main thread blocking on tree load (517c7db)
/// - 8KB binary file detection (2756f29)
///
/// Note: File selection uses `macCGClick` (CGEvent left-click) instead of
/// `macClickButton` (AXPress) because AXPress walks up the AX parent chain
/// and triggers outline-row disclosure toggles instead of List selection.
/// Folder expansion uses `macClickButton` since disclosure toggle is desired.
public enum FileBrowserScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "File Browser",
        tags: ["file-browser", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        TestStep.log("Setup: Create tmux session and launch macOS app")
        TestStep.tmuxCreateSession(name: "filebrowse", width: 160, height: 50)
        Shortcut.tmuxRunCommand(target: "filebrowse:0.0", command: "echo '=== FILE BROWSER TEST ==='")

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        // Select session in sidebar
        TestStep.macWaitForElement(titled: "filebrowse", timeout: 5)
        TestStep.macClickButton(titled: "filebrowse")
        TestStep.wait(seconds: 3)

        // ── Phase 1: Tab Activation & Initial State ──────────────
        TestStep.log("Phase 1: Tab activation and initial empty state")
        TestStep.macScreenshot(label: "mac-terminal-view-baseline")

        // Click the file browser tab (folder icon, accessibilityLabel: "Files")
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 2)

        // Tree should load — wait for a root-level file to appear
        TestStep.macWaitForElement(titled: "README.md", timeout: 10)
        // Detail pane should show "Select a File" placeholder
        TestStep.macWaitForElement(titled: "Select a File", timeout: 5)
        // Dot folders like .claude should be visible
        TestStep.macWaitForElement(titled: ".claude", timeout: 5)
        // OS-level dot files like .DS_Store should be filtered out
        TestStep.macWaitForElementToDisappear(titled: ".DS_Store", timeout: 2)
        TestStep.macScreenshot(label: "mac-file-browser-empty-selection")

        // ── Phase 2: Text File Viewer ────────────────────────────
        TestStep.log("Phase 2: Text file viewer")
        TestStep.macCGClick(titled: "hello.txt")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-text-file-viewer")

        // ── Phase 3: Image Viewer ────────────────────────────────
        TestStep.log("Phase 3: Image viewer")
        TestStep.macCGClick(titled: "photo.png")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-image-viewer")

        // ── Phase 4: PDF Viewer ──────────────────────────────────
        TestStep.log("Phase 4: PDF viewer")
        TestStep.macCGClick(titled: "document.pdf")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-pdf-viewer")

        // ── Phase 5: Video Player ────────────────────────────────
        // Guards against SwiftUI VideoPlayer crash (d278865)
        TestStep.log("Phase 5: Video player (crash regression guard)")
        TestStep.macCGClick(titled: "clip.mp4")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-video-player")

        // ── Phase 6: HTML Viewer ─────────────────────────────────
        TestStep.log("Phase 6: HTML viewer (WebView)")
        TestStep.macCGClick(titled: "page.html")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-html-viewer")

        // ── Phase 7: Unsupported / Binary File ──────────────────
        TestStep.log("Phase 7: Unsupported binary file")
        TestStep.macCGClick(titled: "binary.dat")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "Unable to Read File", timeout: 5)
        TestStep.macScreenshot(label: "mac-unsupported-file")

        // ── Phase 8: Loading Indicator (pending file) ────────────
        // loading.txt hangs on first read — the spinner should show.
        TestStep.log("Phase 8: Loading indicator on pending file")
        TestStep.macCGClick(titled: "loading.txt")
        TestStep.wait(seconds: 2)
        // The spinner should be visible (first read hangs)
        TestStep.macScreenshot(label: "mac-loading-indicator")

        // Select a different file to cancel the hanging read
        TestStep.macCGClick(titled: "hello.txt")
        TestStep.wait(seconds: 1)

        // ── Phase 9: Pending file loads + dynamic folder appears ──
        // Second read of loading.txt succeeds and triggers "generated" folder.
        TestStep.log("Phase 9: Pending file second load + dynamic folder")
        TestStep.macCGClick(titled: "loading.txt")
        TestStep.wait(seconds: 2)
        // Content loads AND the dynamic "generated" folder appears in the tree
        TestStep.macWaitForElement(titled: "generated", timeout: 10)
        TestStep.macScreenshot(label: "mac-pending-file-loaded")

        // ── Phase 10: Markdown Viewer ────────────────────────────
        // Rendered markdown with Textual StructuredText
        TestStep.log("Phase 10: Markdown viewer (Textual StructuredText)")
        TestStep.macCGClick(titled: "README.md")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-markdown-viewer")

        // ── Phase 11: Folder Expansion & Lazy Loading ────────────
        TestStep.log("Phase 11: Lazy folder expansion — src → utils → helper.swift")

        // Expand "src" folder — macClickButton triggers AX disclosure toggle
        TestStep.macClickButton(titled: "src")
        TestStep.wait(seconds: 2)
        // After expanding, "main.swift" should appear
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)

        // Expand "utils" subfolder
        TestStep.macClickButton(titled: "utils")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "helper.swift", timeout: 5)

        // Select the deeply nested file (CGEvent click for selection)
        TestStep.macCGClick(titled: "helper.swift")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-deep-nested-file")

        // ── Phase 12: Expand docs folder and view nested markdown ──
        TestStep.log("Phase 12: Expand docs and view guide.md")
        TestStep.macClickButton(titled: "docs")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "guide.md", timeout: 5)
        TestStep.macCGClick(titled: "guide.md")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-docs-nested-markdown")

        // ── Phase 13: Context Menu ───────────────────────────────
        TestStep.log("Phase 13: Context menu — Copy Path and Copy Relative Path")

        // Copy Path on a file
        TestStep.macContextMenuClick(elementTitle: "hello.txt", menuItem: "Copy Path")
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "copiedPath")
        TestStep.assertStoredContains(key: "copiedPath", substring: "hello.txt")

        // Copy Relative Path
        TestStep.macContextMenuClick(elementTitle: "hello.txt", menuItem: "Copy Relative Path")
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "copiedRelPath")
        TestStep.assertStoredContains(key: "copiedRelPath", substring: "hello.txt")
        // Relative path should NOT contain the directory prefix
        TestStep.assertStoredNotContains(key: "copiedRelPath", substring: "/")

        // Copy Path on a folder
        TestStep.macContextMenuClick(elementTitle: "src", menuItem: "Copy Path")
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "copiedFolderPath")
        TestStep.assertStoredContains(key: "copiedFolderPath", substring: "/src")

        // ── Phase 14: State Persistence — Tab Toggle ─────────────
        // guide.md should still be selected from Phase 12
        TestStep.log("Phase 14: State persistence across tab toggle")

        // Switch back to terminal
        TestStep.macClickButton(titled: "filebrowse:0")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-terminal-restored")

        // Switch back to file browser — state should be preserved
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 2)
        // The previously expanded folders should still show their children
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)
        TestStep.macWaitForElement(titled: "guide.md", timeout: 5)
        TestStep.macScreenshot(label: "mac-file-browser-state-preserved")

        // ── Phase 15: File Search — Matching Results ─────────────
        TestStep.log("Phase 15: File search — matching results")

        // Click the search field and type a query that matches files
        TestStep.macCGClick(titled: "Search files")
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "helper")
        TestStep.wait(seconds: 1)
        // helper.swift should appear in search results
        TestStep.macWaitForElement(titled: "helper.swift", timeout: 5)
        // The tree navigator should be replaced — root-level files shouldn't show
        TestStep.macWaitForElementToDisappear(titled: "README.md", timeout: 3)
        TestStep.macScreenshot(label: "mac-file-search-results")

        // Select a search result and verify detail pane
        TestStep.macCGClick(titled: "helper.swift")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-file-search-selected")

        // ── Phase 16: File Search — No Results ───────────────────
        TestStep.log("Phase 16: File search — no results")

        // Click search field to re-focus, then clear and type a query that matches nothing
        TestStep.macCGClick(titled: "Search files")
        TestStep.wait(seconds: 0.5)
        TestStep.macSelectAll()
        TestStep.macType(text: "zzzznonexistent")
        TestStep.wait(seconds: 1)
        // ContentUnavailableView.search shows "Check the spelling or try a new search."
        TestStep.macWaitForElementQuery(.anyTextMatches("Check the spelling"), timeout: 5)
        TestStep.macScreenshot(label: "mac-file-search-no-results")

        // ── Phase 17: File Search — Persistence Across Tab Switch ─
        TestStep.log("Phase 17: File search persistence across tab switch")

        // Type a real query so we have results to verify after switching back
        TestStep.macCGClick(titled: "Search files")
        TestStep.wait(seconds: 0.5)
        TestStep.macSelectAll()
        TestStep.macType(text: "swift")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)
        TestStep.macScreenshot(label: "mac-file-search-before-tab-switch")

        // Switch to terminal tab
        TestStep.macClickButton(titled: "filebrowse:0")
        TestStep.wait(seconds: 2)

        // Switch back to file browser
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 2)
        // Search query and results should still be there
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)
        TestStep.macWaitForElement(titled: "helper.swift", timeout: 5)
        TestStep.macScreenshot(label: "mac-file-search-after-tab-switch")

        // Clear search to restore tree for remaining phases
        TestStep.macClickButton(titled: "Clear search")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "README.md", timeout: 5)

        // ── Phase 18: Open File in New Tab (context menu) ────────
        TestStep.log("Phase 18: Open in New Tab context menu item creates a file tab")

        // Right-click hello.txt → "Open in New Tab"
        TestStep.macContextMenuClick(elementTitle: "hello.txt", menuItem: "Open in New Tab")
        TestStep.wait(seconds: 2)
        // Tab appears to the right of the Files tab with our accessibility label
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)
        TestStep.macScreenshot(label: "mac-file-tab-opened")

        // ── Phase 19: Switch back to file browser then to file tab ─
        TestStep.log("Phase 19: Switch between Files tab and the new file tab")

        // Click Files tab → tree should be visible again
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "README.md", timeout: 5)
        TestStep.macScreenshot(label: "mac-file-tab-back-to-browser")

        // Click the file tab → file content should be visible again
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-file-tab-reselected")

        // ── Phase 20: Open a second file in another tab ──────────
        TestStep.log("Phase 20: Second file tab opens alongside the first")

        // Go back to the browser so the tree is visible for the right-click
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "README.md", timeout: 5)

        TestStep.macContextMenuClick(elementTitle: "README.md", menuItem: "Open in New Tab")
        TestStep.wait(seconds: 2)
        // Both tabs should now be in the bar
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)
        TestStep.macWaitForElement(titled: "File tab: README.md", timeout: 5)
        TestStep.macScreenshot(label: "mac-two-file-tabs")

        // ── Phase 21: Right-click context menu on file tab (issue #415) ─
        TestStep.log("Phase 21: Right-clicking a file tab shows the shared file context menu")

        // Copy Path on the open file tab — proves the same menu component
        // surfaces on tabs and that the action wires up to the right path.
        TestStep.macContextMenuClick(elementTitle: "File tab: hello.txt", menuItem: "Copy Path")
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "tabCopiedPath")
        TestStep.assertStoredContains(key: "tabCopiedPath", substring: "hello.txt")

        // Copy Relative Path on the open file tab — relative path is the file
        // name only since hello.txt sits at the directory root.
        TestStep.macContextMenuClick(elementTitle: "File tab: hello.txt", menuItem: "Copy Relative Path")
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "tabCopiedRelPath")
        TestStep.assertStoredContains(key: "tabCopiedRelPath", substring: "hello.txt")
        TestStep.assertStoredNotContains(key: "tabCopiedRelPath", substring: "/")

        // ── Phase 22: Show in File Explorer (auto-expands ancestors) ─
        //
        // The "Show in File Explorer" item on a file tab must route the user
        // back to the tree, expand every ancestor folder of the tab's file
        // (even if the user previously collapsed them), and select the file.
        // hello.txt is selected first so the reveal has a different starting
        // selection to move.
        TestStep.log("Phase 22: 'Show in File Explorer' on a file tab expands collapsed parents and selects the file")

        // We're currently on the README.md tab from Phase 20 — switch to the
        // file browser so we can right-click helper.swift in the tree.
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)

        // Collapse the `docs` folder before reaching for helper.swift. With
        // the long.md/long.txt fixtures added for issue #429, the tree now
        // has 19 rows when src+utils+docs are all expanded — one more than
        // the viewport — so helper.swift's AX element ends up just past the
        // bottom edge. `waitForElement` finds it, but `rightClick` posts a
        // CGEvent at its off-screen centre and misses. Closing `docs`
        // reclaims the `guide.md` row so helper.swift fits on screen.
        //
        // Selecting photo.png first moves the right-pane file path header
        // away from `ci/docs/guide.md`. Otherwise the next macClickButton
        // would match the "docs" substring inside the header value and
        // never reach the disclosure caret on the folder row. We avoid
        // hello.txt and README.md here because they are also currently
        // open as file tabs and the tab labels also contain those names.
        TestStep.macCGClick(titled: "photo.png")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "docs")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "guide.md", timeout: 3)
        TestStep.macWaitForElement(titled: "helper.swift", timeout: 5)

        // Open src/utils/helper.swift in a new tab.
        TestStep.macContextMenuClick(elementTitle: "helper.swift", menuItem: "Open in New Tab")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "File tab: helper.swift", timeout: 5)

        // Switch back to the file browser so we can collapse the parent folder.
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)

        // Collapse "src" — main.swift, utils, and helper.swift all hide from the
        // tree. We only check main.swift here because helper.swift is also the
        // text inside the open file tab, which keeps it discoverable in the AX
        // tree even when the tree row is gone.
        TestStep.macClickButton(titled: "src")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "main.swift", timeout: 3)

        // Select photo.png so the tree has a different selection going in;
        // the reveal must move selection onto helper.swift. We avoid hello.txt
        // here because that name also appears as one of the open file tabs,
        // and `macCGClick` would land on the tab text instead of the tree row.
        TestStep.macCGClick(titled: "photo.png")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-show-in-file-explorer-prelude")

        // Right-click the helper.swift file tab → "Show in File Explorer". The
        // action must auto-expand src and src/utils, then route back to the
        // tree with helper.swift selected. We verify expansion via main.swift
        // (only exists in the tree) and selection via the detail pane content
        // (the unique helper.swift body — neither hello.txt nor the file-tab
        // bar contains that string).
        TestStep.macContextMenuClick(elementTitle: "File tab: helper.swift", menuItem: "Show in File Explorer")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)
        TestStep.macWaitForElementQuery(.anyTextMatches("helper function for testing folder recursion"), timeout: 5)
        TestStep.macScreenshot(label: "mac-show-in-file-explorer-revealed")

        // Clean up the helper.swift tab so we don't carry state past this phase.
        TestStep.macClickButton(titled: "File tab: helper.swift")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Close file tab: helper.swift")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "File tab: helper.swift", timeout: 5)

        // ── Phase 23: Close a file tab ───────────────────────────
        TestStep.log("Phase 23: Closing a tab removes only that tab")

        // Select hello.txt tab first so its close button becomes visible
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Close file tab: hello.txt")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "File tab: hello.txt", timeout: 5)
        TestStep.macWaitForElement(titled: "File tab: README.md", timeout: 5)
        TestStep.macScreenshot(label: "mac-file-tab-closed")

        // ── Phase 24: Deleted file keeps tab open with strikethrough ─
        TestStep.log("Phase 24: Deleted file keeps tab open with strikethrough filename")

        // Go back to the browser to pick ephemeral.txt from the tree
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "ephemeral.txt", timeout: 5)

        TestStep.macContextMenuClick(elementTitle: "ephemeral.txt", menuItem: "Open in New Tab")
        TestStep.wait(seconds: 2)
        // Tab is created and the ephemeral read signals deletion — the tab stays
        // put showing a "File Deleted" placeholder.
        TestStep.macWaitForElement(titled: "File tab: ephemeral.txt", timeout: 5)
        TestStep.macWaitForElement(titled: "File Deleted", timeout: 5)
        TestStep.macScreenshot(label: "mac-file-tab-deleted-strikethrough")

        // Close the ephemeral.txt tab so "ephemeral.txt" only comes from the
        // tree in the next assertion; if deletion propagated correctly the tree
        // no longer has a row for it either.
        TestStep.macClickButton(titled: "Close file tab: ephemeral.txt")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "File tab: ephemeral.txt", timeout: 5)
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "ephemeral.txt", timeout: 5)

        // Clean up the remaining README.md tab so we don't carry state into the next phase.
        TestStep.macClickButton(titled: "File tab: README.md")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Close file tab: README.md")
        TestStep.wait(seconds: 1)

        // ── Phase 25: Window tab visual state with a file tab selected ─
        //
        // Regression guard for PR #399 issue 1: before the fix, selecting a file
        // tab also painted the underlying tmux window tab as selected (both got
        // the accent background + underline). The screenshot here is the
        // assertion — the terminal tab must not show the selected styling while
        // the file tab is the active view.
        TestStep.log("Phase 25: Selected file tab does not paint the window tab as selected")

        TestStep.macContextMenuClick(elementTitle: "hello.txt", menuItem: "Open in New Tab")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)
        TestStep.macScreenshot(label: "mac-file-tab-selected-window-tab-deselected")

        // ── Phase 26: File tabs persist across window switch (session-scoped) ─
        //
        // Regression guard for PR #399 issue 2: before the fix, openFileTabs
        // lived on per-window FileBrowserState so switching tmux windows wiped
        // the tab strip. The wait-for-element assertion fails on the broken
        // version; the screenshots verify the visual state.
        //
        // This phase also implicitly verifies that the file browser tree is
        // still per-window (it does NOT auto-follow into the new window), which
        // was the original Phase 23 regression check.
        TestStep.log("Phase 26: File tabs persist across tmux window switch within a session")

        // Create a second tmux window in the same session
        Shortcut.tmuxRunCommand(target: "filebrowse:0.0", command: "tmux new-window -t filebrowse")
        TestStep.wait(seconds: 3)
        Shortcut.tmuxRunCommand(target: "filebrowse:1.0", command: "echo '=== WINDOW 1 ==='")
        TestStep.wait(seconds: 2)

        // Switch to window 1 — file tab must still be visible in the bar, but
        // the content area should show the terminal (the Files-tab active flag
        // is per-window, so a freshly-switched-to window lands on the terminal
        // tab even though the underlying file browser state is now session-
        // scoped per commit 90f1d8f).
        TestStep.macClickButton(titled: "filebrowse:1")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "README.md", timeout: 3)
        TestStep.macScreenshot(label: "mac-window-switch-tab-persists")

        // Click the file tab while on window 1 — file content should display.
        // The path header shows the path relative to the window-0 directory
        // (the originating directoryPath stored on the tab), which is the
        // session's project root.
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-file-tab-from-other-window")

        // Switch back to window 0 — file tab still visible, terminal restored.
        TestStep.macClickButton(titled: "filebrowse:0")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)
        TestStep.macScreenshot(label: "mac-window-switch-back-tab-persists")

        // Close the tab so we don't carry state past the scenario.
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Close file tab: hello.txt")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "File tab: hello.txt", timeout: 5)

        // ── Persistent alt session for Phases 27-31 ──────────────
        //
        // The five scroll-preservation phases each verify a session round
        // trip. Creating + tearing down an alt tmux session per phase costs
        // ~5s × 5 = ~25s of test runtime; instead we set up a single
        // `scrollalt` here and reuse it for every session round trip. The
        // session is destroyed at the end of the scenario.
        TestStep.tmuxCreateSession(name: "scrollalt", width: 160, height: 50)
        Shortcut.tmuxRunCommand(target: "scrollalt:0.0", command: "echo '=== ALT SESSION ==='")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "scrollalt", timeout: 5)

        // ── Phase 27: Scroll position persists across tab and session switches ─
        //
        // Regression guard for issue #429: opening a long file in a tab,
        // scrolling down, then switching to another tmux window or session
        // and returning used to drop the user back to the top of the file.
        // The tab now stores its scroll offset on `SessionFileTabsState`,
        // so the saved position must be restored on re-mount in both cases.
        //
        // The "BOTTOM MARKER" string is what we assert against — `long.md`
        // is laid out so that string only appears in the screenshot when
        // the scroll position has been preserved at the bottom of the file.
        //
        // Tab round trip uses `filebrowse:0` (window 0's terminal tab).
        TestStep.log("Phase 27: Scroll position preserved across tab/session switch (markdown, window 0)")

        // Open `long.md` from the file browser tree as its own tab.
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "long.md", timeout: 5)
        TestStep.macContextMenuClick(elementTitle: "long.md", menuItem: "Open in New Tab")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "File tab: long.md", timeout: 5)
        // Initial render — scrolled to the very top, BOTTOM MARKER is offscreen.
        TestStep.macWaitForElementQuery(.anyTextMatches("Scroll Preservation Test"), timeout: 5)
        TestStep.macScreenshot(label: "mac-scroll-preserve-top")

        // Scroll down enough to reach the bottom of the file. Using a
        // CGEvent scroll wheel (negative deltaY = down) at the window
        // centre, which lands inside the markdown viewer.
        TestStep.macScrollWheel(deltaY: -10, count: 40)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("BOTTOM MARKER"), timeout: 5)
        TestStep.macScreenshot(label: "mac-scroll-preserve-bottom-initial")

        // Tab round trip via window 0's terminal.
        TestStep.macClickButton(titled: "filebrowse:0")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "File tab: long.md")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("BOTTOM MARKER"), timeout: 5)
        TestStep.macScreenshot(label: "mac-scroll-preserve-after-tab-switch")

        // Session round trip via the persistent `scrollalt`.
        TestStep.macClickButton(titled: "scrollalt")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "filebrowse")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "File tab: long.md")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("BOTTOM MARKER"), timeout: 5)
        TestStep.macScreenshot(label: "mac-scroll-preserve-after-session-switch")

        // Close the tab — the scroll offset is dropped by the tab close
        // handler, so the next phase re-opens with a fresh state.
        TestStep.macClickButton(titled: "Close file tab: long.md")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "File tab: long.md", timeout: 5)

        // ── Phase 28: Scroll position persists for the plain-text viewer ─
        //
        // Mirrors Phase 27 against `long.txt`. The plain-text viewer
        // (`PlainTextContentView`) is a separate SwiftUI implementation from
        // the markdown viewer, so the same persistence guarantee needs its
        // own coverage. The "TEXT BOTTOM MARKER" string is unique to the
        // plain-text fixture so the assertion only matches when the viewer
        // is actually scrolled to the bottom.
        //
        // Tab round trip uses `filebrowse:1` (window 1) instead of
        // `filebrowse:0` — earlier versions of the file-tab restoration
        // didn't preserve scroll when the user returned via a sibling
        // window's terminal, only when they returned via the same window.
        TestStep.log("Phase 28: Scroll position preserved for the plain-text viewer (window 1)")

        // Open `long.txt` from the file browser tree as its own tab.
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "long.txt", timeout: 5)
        TestStep.macContextMenuClick(elementTitle: "long.txt", menuItem: "Open in New Tab")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "File tab: long.txt", timeout: 5)
        TestStep.macWaitForElementQuery(.anyTextMatches("Scroll Preservation Test (Plain Text)"), timeout: 5)
        TestStep.macScreenshot(label: "mac-text-scroll-preserve-top")

        // Scroll to the bottom of the file.
        TestStep.macScrollWheel(deltaY: -10, count: 40)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("TEXT BOTTOM MARKER"), timeout: 5)
        TestStep.macScreenshot(label: "mac-text-scroll-preserve-bottom-initial")

        // Tab round trip via window 1's terminal — exercises the
        // "returning from a different window" code path.
        TestStep.macClickButton(titled: "filebrowse:1")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "File tab: long.txt")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("TEXT BOTTOM MARKER"), timeout: 5)
        TestStep.macScreenshot(label: "mac-text-scroll-preserve-after-tab-switch")

        // Session round trip via the shared `scrollalt`.
        TestStep.macClickButton(titled: "scrollalt")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "filebrowse")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "File tab: long.txt")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("TEXT BOTTOM MARKER"), timeout: 5)
        TestStep.macScreenshot(label: "mac-text-scroll-preserve-after-session-switch")

        // Close the tab so the next phase starts fresh.
        TestStep.macClickButton(titled: "Close file tab: long.txt")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "File tab: long.txt", timeout: 5)

        // ── Phase 29: Detail pane scroll preservation ────────────
        //
        // Regression guard for commit ed62fdb. The detail pane (file selected
        // via the tree, no "Open in New Tab") stores its scroll offset on
        // `FileBrowserState.scrollOffsets[absolutePath]` — a different store
        // and binding from the open-file-tab path verified in Phase 27/28. We
        // open `long.md` by single-click in the tree, scroll to the bottom,
        // then verify the position survives a tab round-trip and a session
        // round-trip.
        //
        // The window is resized taller for the remaining phases so that
        // Phase 32 can keep `helper.swift` / `main.swift` on screen at the
        // same time as the (now session-scoped) search results, even with
        // `src` and `src/utils` both expanded.
        TestStep.log("Phase 29: Detail pane preserves scroll position across tab and session switches")
        TestStep.macResizeWindow(width: 1_200, height: 800)
        TestStep.wait(seconds: 1)

        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "long.md", timeout: 5)
        // Single-click selects the file in the tree → loads in the detail pane.
        TestStep.macCGClick(titled: "long.md")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("Scroll Preservation Test"), timeout: 5)
        TestStep.macScreenshot(label: "mac-detail-scroll-preserve-top")

        // Scroll to the bottom — BOTTOM MARKER becomes visible.
        TestStep.macScrollWheel(deltaY: -10, count: 40)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("BOTTOM MARKER"), timeout: 5)
        TestStep.macScreenshot(label: "mac-detail-scroll-preserve-bottom-initial")

        // Tab round trip via window 0's terminal → back to Files. Detail
        // pane is rebuilt and must restore the saved offset from
        // `state.scrollOffsets`.
        TestStep.macClickButton(titled: "filebrowse:0")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("BOTTOM MARKER"), timeout: 5)
        TestStep.macScreenshot(label: "mac-detail-scroll-preserve-after-tab-switch")

        // Session round trip via the shared `scrollalt`. State is keyed by
        // session, so the offset survives leaving and returning to filebrowse.
        TestStep.macClickButton(titled: "scrollalt")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "filebrowse")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("BOTTOM MARKER"), timeout: 5)
        TestStep.macScreenshot(label: "mac-detail-scroll-preserve-after-session-switch")

        // ── Phase 30: HTML viewer scroll preservation ────────────
        //
        // Regression guard for commit f9b9035 (HTML half). The new
        // `ScrollableWebView` (macOS 26+) drives the WKWebView scroll position
        // through `webViewScrollPosition` and rebroadcasts user scrolls via
        // `webViewOnScrollGeometryChange`. The "HTML BOTTOM MARKER" `<h1>` at
        // the end of `page.html` only renders on screen once the WebView has
        // scrolled all the way down.
        //
        // Tab round trip uses `filebrowse:1` to exercise the cross-window
        // return path for the WebView restore.
        TestStep.log("Phase 30: HTML viewer preserves scroll (window 1)")

        TestStep.macWaitForElement(titled: "page.html", timeout: 5)
        TestStep.macContextMenuClick(elementTitle: "page.html", menuItem: "Open in New Tab")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "File tab: page.html", timeout: 5)
        // The WebView needs a moment to load before AX text is available. The
        // 250ms warm-up before scroll restore in `ScrollableWebView` covers
        // the same async growth on rebuild, so a short wait here is enough.
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("Scroll Preservation Test (HTML)"), timeout: 5)
        TestStep.macScreenshot(label: "mac-html-scroll-preserve-top")

        TestStep.macScrollWheel(deltaY: -10, count: 40)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("HTML BOTTOM MARKER"), timeout: 5)
        TestStep.macScreenshot(label: "mac-html-scroll-preserve-bottom-initial")

        // Tab round trip via window 1's terminal.
        TestStep.macClickButton(titled: "filebrowse:1")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "File tab: page.html")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("HTML BOTTOM MARKER"), timeout: 5)
        TestStep.macScreenshot(label: "mac-html-scroll-preserve-after-tab-switch")

        // Session round trip via the shared `scrollalt`.
        TestStep.macClickButton(titled: "scrollalt")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "filebrowse")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "File tab: page.html")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("HTML BOTTOM MARKER"), timeout: 5)
        TestStep.macScreenshot(label: "mac-html-scroll-preserve-after-session-switch")

        // Close the tab so the next phase starts fresh.
        TestStep.macClickButton(titled: "Close file tab: page.html")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "File tab: page.html", timeout: 5)

        // ── Phase 31: PDF viewer scroll preservation ─────────────
        //
        // Regression guard for commit f9b9035 (PDF half). `PDFViewRepresentable`
        // observes the inner `NSClipView` bounds for user scrolls and writes
        // back to the binding, then re-applies the saved Y on rebuild. The
        // bundled `test_pdf.pdf` is 3 pages — "Buildable Folders" only appears
        // on page 2, so it's the assertion target for "scrolled past page 1".
        TestStep.log("Phase 31: PDF viewer preserves scroll across tab/session switches")

        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "document.pdf", timeout: 5)
        TestStep.macContextMenuClick(elementTitle: "document.pdf", menuItem: "Open in New Tab")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "File tab: document.pdf", timeout: 5)
        // Initial render is page 1 — "Buildable Folders" should NOT be visible.
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-pdf-scroll-preserve-top")

        // Smaller scroll count than the markdown/HTML phases — `test_pdf.pdf`
        // is only 3 pages, and overshooting past the last page would land in
        // PDFView's empty grey area, which makes the screenshot baseline
        // useless. Six ticks at deltaY=-10 lands mid-document around page 2.
        TestStep.macScrollWheel(deltaY: -10, count: 6)
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("Buildable Folders"), timeout: 5)
        TestStep.macScreenshot(label: "mac-pdf-scroll-preserve-bottom-initial")

        // Tab round trip via window 0's terminal.
        TestStep.macClickButton(titled: "filebrowse:0")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "File tab: document.pdf")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("Buildable Folders"), timeout: 5)
        TestStep.macScreenshot(label: "mac-pdf-scroll-preserve-after-tab-switch")

        // Session round trip via the shared `scrollalt`.
        TestStep.macClickButton(titled: "scrollalt")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "filebrowse")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "File tab: document.pdf")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("Buildable Folders"), timeout: 5)
        TestStep.macScreenshot(label: "mac-pdf-scroll-preserve-after-session-switch")

        // Close the tab so the next phase starts fresh.
        TestStep.macClickButton(titled: "Close file tab: document.pdf")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementToDisappear(titled: "File tab: document.pdf", timeout: 5)

        // ── Phase 32: File browser state shared across windows ───
        //
        // Regression guard for commit 90f1d8f. `fileBrowserStates` is now keyed
        // by `sessionName` (was `windowId`), so the explorer's search query,
        // selection, expansion, and per-path scroll all persist when the
        // user switches between sibling tmux windows in the same session.
        // We use `filebrowse:1` (created in Phase 26 and never torn down) to
        // avoid an extra `tmux new-window` round trip.
        //
        // The phase exercises search-state and selection sharing — both
        // independent signals on `FileBrowserState` — and additionally
        // proves the propagation works in both directions by mutating the
        // selection on window 1 and re-asserting on window 0.
        TestStep.log("Phase 32: File browser state is shared across windows in the same session")

        // Set up state on window 0 by typing into the search field. Search is
        // chosen as the cross-window probe because it's robust to whatever
        // tree-expansion state earlier phases left behind (the failed alt-
        // session round trips in Phases 27-31 do not preserve folder
        // expansions reliably, but the explicit FileBrowserState fields —
        // `searchQuery`, `selectedSearchPath` — are session-scoped). Once
        // `searchQuery` is "swift", `main.swift` and `helper.swift` are in
        // the result list regardless of expansion, and `README.md` is
        // filtered out — three independent signals we can re-assert on
        // window 1.
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "README.md", timeout: 5)
        TestStep.macCGClick(titled: "Search files")
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "swift")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)
        TestStep.macWaitForElement(titled: "helper.swift", timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "README.md", timeout: 3)

        // Select `helper.swift` from the search results so the detail pane
        // shows its body — the "helper function for testing folder recursion"
        // string is the assertion target for "selection is shared".
        TestStep.macCGClick(titled: "helper.swift")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("helper function for testing folder recursion"), timeout: 5)
        TestStep.macScreenshot(label: "mac-cross-window-state-window0")

        // Switch to window 1 and click Files. Before commit 90f1d8f the
        // explorer would rebuild from scratch on window 1 (empty search,
        // empty selection). With the fix, the search query, the result list,
        // and the selected detail pane are identical to window 0.
        TestStep.macClickButton(titled: "filebrowse:1")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)
        TestStep.macWaitForElement(titled: "helper.swift", timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "README.md", timeout: 3)
        TestStep.macWaitForElementQuery(.anyTextMatches("helper function for testing folder recursion"), timeout: 5)
        TestStep.macScreenshot(label: "mac-cross-window-state-window1")

        // Mutate state on window 1: pick a different search result. The new
        // selection should propagate back to window 0.
        TestStep.macCGClick(titled: "main.swift")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("@main"), timeout: 5)
        TestStep.macScreenshot(label: "mac-cross-window-state-window1-mutated")

        // Switch back to window 0 → window 1's mutation is visible here too.
        TestStep.macClickButton(titled: "filebrowse:0")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "README.md", timeout: 3)
        TestStep.macWaitForElementQuery(.anyTextMatches("@main"), timeout: 5)
        TestStep.macScreenshot(label: "mac-cross-window-state-window0-restored")

        // Tear down the persistent alt session and both filebrowse windows.
        Shortcut.tmuxRunCommand(target: "scrollalt:0.0", command: "exit")
        TestStep.wait(seconds: 2)
        Shortcut.tmuxRunCommand(target: "filebrowse:1.0", command: "exit")
        TestStep.wait(seconds: 2)
        Shortcut.tmuxRunCommand(target: "filebrowse:0.0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
