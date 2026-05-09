import Foundation

/// E2E scenario: File Text (Content) Search
///
/// Exercises the full-text content search added in issue #432:
/// 1. Search-mode picker (Name | Content) toggles which kind of results the
///    file explorer shows for the current query.
/// 2. Content mode searches inside file bodies and surfaces every matching
///    line with file path + line number + snippet.
/// 3. Clicking a content-search result loads that file in the detail pane.
/// 4. The same right-click context menu offered on tree rows (Copy Path,
///    Copy Relative Path, Open, Show in Finder, …) is also available on
///    content-search and name-search result cells.
/// 5. An empty content query yields a "Search File Contents" placeholder;
///    a query with no matches falls through to `ContentUnavailableView.search`.
/// 6. Toggling back to Name mode after a content search re-uses the typed
///    query against the file-name index (the picker preserves the query so
///    users don't have to retype).
///
/// The fake filesystem registered for E2E by `ClaudeSpyServerApp` includes
/// hello.txt ("Hello, world!") and src/main.swift (`print("Hello, world!")`),
/// so a content search for `Hello` produces multiple matches across files —
/// enough to exercise the per-line result row layout.
public enum FileTextSearchScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "File Text Search",
        tags: ["file-browser", "file-text-search", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        TestStep.log("Setup: Create tmux session and launch macOS app")
        TestStep.tmuxCreateSession(name: "filetextsearch", width: 160, height: 50)
        Shortcut.tmuxRunCommand(target: "filetextsearch:0.0", command: "echo '=== FILE TEXT SEARCH TEST ==='")

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        // Select session in sidebar
        TestStep.macWaitForElement(titled: "filetextsearch", timeout: 5)
        TestStep.macClickButton(titled: "filetextsearch")
        TestStep.wait(seconds: 3)

        // Open the file browser tab.
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "README.md", timeout: 10)

        // ── Phase 1: Default (Name) mode renders the existing search UI ──
        TestStep.log("Phase 1: Search field defaults to Name mode")

        // Focus the search field (Name mode default) and type a query that
        // the existing file-name index resolves to a single file.
        TestStep.macCGClick(titled: "Search files")
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "hello")
        TestStep.wait(seconds: 1)
        // hello.txt matches by name; README.md should be hidden.
        TestStep.macWaitForElement(titled: "hello.txt", timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "README.md", timeout: 3)
        TestStep.macScreenshot(label: "mac-text-search-name-mode-baseline")

        // ── Phase 2: Switch to Content mode while the query is preserved ──
        TestStep.log("Phase 2: Switch to Content mode — query is preserved, results refresh")

        TestStep.macClickButton(titled: "Content")
        TestStep.wait(seconds: 2)

        // The content search for "hello" matches hello.txt's body and
        // src/main.swift's `print("Hello, world!")`. Both files should
        // appear in the result list. We assert via the line snippet that
        // is unique to each match — the row label includes the filename
        // plus ":<line>" so we can also confirm the line-number suffix is
        // rendered by waiting on a substring like ":1" / ":6".
        TestStep.macWaitForElement(titled: "hello.txt", timeout: 10)
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)
        TestStep.macWaitForElementQuery(.anyTextMatches("Hello, world"), timeout: 5)
        TestStep.macScreenshot(label: "mac-text-search-content-results")

        // ── Phase 3: Selecting a content match opens that file ──
        TestStep.log("Phase 3: Selecting a content-search result loads the file in the detail pane")

        // Results are now grouped by file: each file is a DisclosureGroup
        // header whose accessibility label is the file name, and individual
        // match rows live under it labelled "Line <n>: <line>". Clicking
        // the header would toggle disclosure rather than selecting, so we
        // target hello.txt's match row directly. The detail pane should
        // then show the file body including the second line "This is a
        // plain text file." — used as the assertion target since it
        // doesn't appear in any other fake-file fixture.
        TestStep.macCGClick(titled: "Line 1: Hello, world!")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("This is a plain text file"), timeout: 5)
        TestStep.macScreenshot(label: "mac-text-search-content-selected")

        // ── Phase 4: Right-click menu on a content-search result ──
        TestStep.log("Phase 4: Context menu — Copy Path on a content-search result")

        // The match-cell context menu reuses `fileContextMenu`. Copy Path
        // round-trips through the clipboard so we can prove both that the
        // menu surfaces and that the right path is wired up to the action.
        TestStep.macContextMenuClick(elementTitle: "main.swift", menuItem: "Copy Path")
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "contentSearchCopiedPath")
        TestStep.assertStoredContains(key: "contentSearchCopiedPath", substring: "main.swift")
        TestStep.assertStoredContains(key: "contentSearchCopiedPath", substring: "/src/")

        // Copy Relative Path on the same row — proves the relative form is
        // computed against the directory root, not the absolute path.
        TestStep.macContextMenuClick(elementTitle: "main.swift", menuItem: "Copy Relative Path")
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "contentSearchCopiedRel")
        TestStep.assertStoredContains(key: "contentSearchCopiedRel", substring: "src/main.swift")
        TestStep.assertStoredNotContains(key: "contentSearchCopiedRel", substring: "/Users/")

        // ── Phase 5: No-results state in content mode ──
        TestStep.log("Phase 5: Content search with no matches falls through to the empty state")

        TestStep.macCGClick(titled: "Search file contents")
        TestStep.wait(seconds: 0.5)
        TestStep.macSelectAll()
        TestStep.macType(text: "zzznonexistentcontent")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("Check the spelling"), timeout: 5)
        TestStep.macScreenshot(label: "mac-text-search-content-no-results")

        // ── Phase 6: Switch back to Name mode preserves the query ──
        TestStep.log("Phase 6: Toggle back to Name mode — query persists, name index is used")

        // Reset to a query that hits a unique source comment so we can
        // tell name-mode and content-mode results apart by inspecting the
        // visible AX text. helper.swift's only line containing `helper`
        // is the doc comment `/// A helper function for testing folder
        // recursion.` — which the content-search row renders below the
        // file name + line number, and the name-search row does not.
        TestStep.macCGClick(titled: "Search file contents")
        TestStep.wait(seconds: 0.5)
        TestStep.macSelectAll()
        TestStep.macType(text: "helper")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "helper.swift", timeout: 5)
        TestStep.macWaitForElementQuery(.anyTextMatches("A helper function"), timeout: 5)

        // Toggle to Name mode. The same query becomes a fuzzy file-name
        // search; helper.swift still appears, but the row no longer shows
        // the source-line snippet — we check for the directory crumb
        // ("src/utils") that the name-search row renders below the name,
        // and assert that the snippet text from content-mode is gone.
        TestStep.macClickButton(titled: "Name")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "helper.swift", timeout: 5)
        TestStep.macWaitForElementQuery(.anyTextMatches("src/utils"), timeout: 5)
        TestStep.macWaitForElementQueryToDisappear(.anyTextMatches("A helper function"), timeout: 5)
        TestStep.macScreenshot(label: "mac-text-search-back-to-name")

        // ── Phase 7: Clearing the query restores the tree ──
        TestStep.log("Phase 7: Clear search restores the file tree")

        TestStep.macClickButton(titled: "Clear search")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "README.md", timeout: 5)
        TestStep.macScreenshot(label: "mac-text-search-tree-restored")

        // Tear down the tmux session so leftover state doesn't bleed into
        // subsequent scenarios.
        Shortcut.tmuxRunCommand(target: "filetextsearch:0.0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
