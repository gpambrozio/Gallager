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
/// 5. Switching to a different tab and back preserves the content-search
///    cache and the selected match — no re-walk of the tree, no lost
///    selection (a cached-query gate on `recomputeContentSearchResults`).
/// 6. The same is true after switching to a sibling session and back: the
///    per-session `FileBrowserState` retains its query, results, and
///    selected match across the round trip.
/// 7. An empty content query yields a "Search File Contents" placeholder;
///    a query with no matches falls through to `ContentUnavailableView.search`.
/// 8. Toggling back to Name mode after a content search re-uses the typed
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

        // ── Phase 5: Tab switch preserves the cached search + selection ──
        TestStep.log("Phase 5: Leaving the Files tab and returning preserves results and selection")

        // Phase 4's right-click likely shifted the row selection onto
        // main.swift, so re-pin it to hello.txt's match for a deterministic
        // assertion target after we round-trip tabs.
        TestStep.macCGClick(titled: "Line 1: Hello, world!")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElementQuery(.anyTextMatches("This is a plain text file"), timeout: 5)

        // Switch to the tmux window's terminal tab. The file-browser view
        // disappears and its `.onDisappear` cancels any in-flight search,
        // but the cached results and selection live on the parent state.
        TestStep.macClickButton(titled: "filetextsearch:0")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("FILE TEXT SEARCH TEST"), timeout: 5)
        TestStep.macWaitForElementQueryToDisappear(.anyTextMatches("This is a plain text file"), timeout: 3)
        TestStep.macScreenshot(label: "mac-text-search-tab-switch-terminal")

        // Return to the Files tab. Without the cached-query gate the
        // `.onChange(initial: true)` re-fire would blow the cache away and
        // re-run the file walk, losing the selection; with the gate the
        // same results, the snippet text, and the loaded file body all
        // survive the round trip.
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "hello.txt", timeout: 5)
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)
        TestStep.macWaitForElementQuery(.anyTextMatches("Hello, world"), timeout: 5)
        TestStep.macWaitForElementQuery(.anyTextMatches("This is a plain text file"), timeout: 5)
        TestStep.macScreenshot(label: "mac-text-search-tab-switch-back")

        // ── Phase 6: Session switch also preserves the cache + selection ──
        TestStep.log("Phase 6: Switching sessions and returning preserves results and selection")

        // FileBrowserState lives on MainView keyed by session name, so a
        // session round-trip rebuilds the FileBrowserView against the same
        // state instance — same `.onChange(initial: true)` flow as the tab
        // switch, exercised here against a fresh sibling session.
        //
        // The alt session uses a name that does NOT share a substring with
        // "filetextsearch" so `macClickButton(titled:)` (which is substring-
        // based) unambiguously targets each sidebar entry.
        TestStep.tmuxCreateSession(name: "alt-session", width: 160, height: 50)
        Shortcut.tmuxRunCommand(target: "alt-session:0.0", command: "echo '=== ALT SESSION TERMINAL ==='")
        TestStep.wait(seconds: 2)

        // Switch to the alt session. Its window is not in
        // `fileBrowserActiveWindowIds`, so the content area shows its
        // terminal — verifiable via the echo banner above. The detail-pane
        // text from the original session must disappear.
        TestStep.macClickButton(titled: "alt-session")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("ALT SESSION TERMINAL"), timeout: 5)
        TestStep.macWaitForElementQueryToDisappear(.anyTextMatches("This is a plain text file"), timeout: 3)
        TestStep.macScreenshot(label: "mac-text-search-session-switch-alt")

        // Switch back to the original session. The Files tab activity flag
        // is per-window so `filetextsearch:0` is still flagged; the Files
        // tab re-renders without us clicking it. The cached results, the
        // "hello" query, and the previously-loaded file body must all
        // survive — same assertions as the tab-switch round trip.
        TestStep.macClickButton(titled: "filetextsearch")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "hello.txt", timeout: 5)
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)
        TestStep.macWaitForElementQuery(.anyTextMatches("Hello, world"), timeout: 5)
        TestStep.macWaitForElementQuery(.anyTextMatches("This is a plain text file"), timeout: 5)
        TestStep.macScreenshot(label: "mac-text-search-session-switch-back")

        // ── Phase 7: No-results state in content mode ──
        TestStep.log("Phase 7: Content search with no matches falls through to the empty state")

        TestStep.macCGClick(titled: "Search contents")
        TestStep.wait(seconds: 0.5)
        TestStep.macPressKey(.character("a"), modifiers: .command)
        TestStep.macType(text: "zzznonexistentcontent")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementQuery(.anyTextMatches("Check the spelling"), timeout: 5)
        TestStep.macScreenshot(label: "mac-text-search-content-no-results")

        // ── Phase 8: Switch back to Name mode preserves the query ──
        TestStep.log("Phase 8: Toggle back to Name mode — query persists, name index is used")

        // Reset to a query that hits a unique source comment so we can
        // tell name-mode and content-mode results apart by inspecting the
        // visible AX text. helper.swift's only line containing `helper`
        // is the doc comment `/// A helper function for testing folder
        // recursion.` — which the content-search row renders below the
        // file name + line number, and the name-search row does not.
        TestStep.macCGClick(titled: "Search contents")
        TestStep.wait(seconds: 0.5)
        TestStep.macPressKey(.character("a"), modifiers: .command)
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

        // ── Phase 9: Clearing the query restores the tree ──
        TestStep.log("Phase 9: Clear search restores the file tree")

        TestStep.macClickButton(titled: "Clear search")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "README.md", timeout: 5)
        TestStep.macScreenshot(label: "mac-text-search-tree-restored")

        // ── Phase 10: Deep-line content match scrolls + highlights ──
        TestStep.log("Phase 10: Markdown match scrolls plain-text viewer to a deep line and highlights it")

        // Re-enter Content mode (Phase 8 toggled to Name; Phase 9 cleared
        // the query). We search for `## BOTTOM` — a substring that only
        // appears in `long.md`'s heading on line 128, well past the
        // viewport top of the detail pane. Clicking the match must
        //   (a) render `long.md` as plain text via `forceTextViewer`
        //       (the markdown viewer would otherwise render `##` as a
        //       heading and hide the literal line we just matched on),
        //   (b) scroll the text view so line 128 lands roughly at the
        //       viewport centre — `## BOTTOM MARKER` would be off-screen
        //       in a default top-anchored layout for a 130-line file in
        //       a ~600pt-tall pane, so visibility proves the scroll
        //       actually happened, and
        //   (c) paint the matched line via `HighlightingTextView`'s
        //       `drawBackground(in:)` override.
        // The screenshot baseline is the visual proof for (a) and (c) —
        // NSTextView exposes its full text via `AXValue` regardless of
        // scroll, so we can't AX-assert that the top of the file was
        // scrolled off, but we can assert the match row resolved to the
        // correct line number and that the file body loaded into the
        // detail pane.
        TestStep.macClickButton(titled: "Content")
        TestStep.wait(seconds: 1)
        TestStep.macCGClick(titled: "Search contents")
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "## BOTTOM")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "long.md", timeout: 5)
        TestStep.macWaitForElementQuery(.anyTextMatches("Line 128: ## BOTTOM MARKER"), timeout: 5)

        TestStep.macCGClick(titled: "Line 128: ## BOTTOM MARKER")
        TestStep.wait(seconds: 1)
        // `If you can read this line, you are at the bottom of the file.`
        // is line 130 of `long.md`, immediately after the matched
        // heading. Its appearance in the AX tree confirms `long.md`'s
        // body was loaded into the detail pane (and not, say, blocked
        // on the markdown renderer).
        TestStep.macWaitForElementQuery(.anyTextMatches("If you can read this line"), timeout: 5)
        TestStep.macScreenshot(label: "mac-text-search-scroll-to-line")

        // Tear down the tmux session so leftover state doesn't bleed into
        // subsequent scenarios.
        Shortcut.tmuxRunCommand(target: "filetextsearch:0.0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
