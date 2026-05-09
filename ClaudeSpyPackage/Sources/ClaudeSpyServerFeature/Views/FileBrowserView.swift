import AppKit
import AVKit
import ClaudeSpyCommon
import Dependencies
import Files
import PDFKit
import ProjectNavigator
import SwiftUI
import Textual
import WebKit

/// OS-level entries to hide in the file navigator (same as skippedEntries in the service).
private let skippedNavigatorEntries: Set = [
    ".DS_Store", ".Trash", ".Spotlight-V100", ".fseventsd",
    ".TemporaryItems", ".DocumentRevisions-V100",
]

/// Which kind of search the file browser is currently performing.
enum FileSearchMode: String, CaseIterable, Sendable {
    /// Match file names / paths (existing behavior).
    case name
    /// Match the contents of files (issue #432).
    case content
}

/// A file opened as its own tab to the right of the file explorer tab.
/// Identified by a stable UUID so re-opens select the existing tab and
/// deletion state can be tracked without losing the tab.
///
/// `directoryPath` is the file-browser root that originated the tab; the path
/// header renders relative to this so the displayed path stays stable when the
/// user switches to a sibling tmux window with a different cwd.
///
/// `originWindowId` is the tmux window that initiated the tab open via a
/// terminal click. When set, closing the tab returns the user to that
/// terminal instead of falling back to the file browser tree.
struct OpenFileTab: Identifiable, Equatable {
    let id: UUID
    let path: String
    let directoryPath: String
    var isDeleted: Bool
    var originWindowId: String?

    init(
        id: UUID = UUID(),
        path: String,
        directoryPath: String,
        isDeleted: Bool = false,
        originWindowId: String? = nil
    ) {
        self.id = id
        self.path = path
        self.directoryPath = directoryPath
        self.isDeleted = isDeleted
        self.originWindowId = originWindowId
    }

    var name: String {
        (path as NSString).lastPathComponent
    }
}

/// Cached state for a file browser, keyed by window ID.
/// Stored in MainView so it survives tab/session switches.
@Observable
@MainActor
final class FileBrowserState {
    var viewState: FileNavigatorViewState<TextFileContents>?
    var sidebarWidth: CGFloat = 250
    /// The directory path this state was loaded for; used to detect stale caches.
    var loadedPath: String?
    /// Maps filesystem paths to stable UUIDs so tree rebuilds preserve expansion/selection.
    var stableIds: [String: UUID] = [:] {
        didSet { reverseIds = Dictionary(stableIds.map { ($1, $0) }, uniquingKeysWith: { first, _ in first }) }
    }

    /// Cached reverse mapping from UUID to filesystem path, updated when `stableIds` changes.
    private(set) var reverseIds: [UUID: String] = [:]
    /// Folder paths whose children have been loaded.
    var loadedFolderPaths: Set<String> = []
    /// Filesystem paths that are symbolic links, used to render them with a
    /// distinct visual style in the navigator.
    var symlinkedPaths: Set<String> = []
    /// All files under the directory, cached for search.
    var allFiles: [FileSearchResult] = []
    /// The directory path for which `allFiles` was loaded.
    var allFilesDirectoryPath: String?
    /// Current search query, preserved across tab switches.
    var searchQuery = ""
    /// Whether the user is searching by file name (default) or by file
    /// contents. Both modes share `searchQuery` so toggling preserves what the
    /// user already typed.
    var searchMode: FileSearchMode = .name
    /// Selected file path in name-search results, preserved across tab switches.
    var selectedSearchPath: String?
    /// Cached file-name results matching the current query.
    var cachedSearchResults: [FileSearchResult] = []
    /// Cached content-search matches for the current query.
    var cachedContentSearchResults: [FileTextSearchMatch] = []
    /// Selected match id (`fullPath:lineNumber`) in the content-search list.
    var selectedContentSearchMatchID: String?
    /// True while a content search is running for the current query, so the
    /// UI can show a progress indicator until the first batch lands.
    var isContentSearchRunning = false
    /// When set, the navigator expands every ancestor folder, selects this path,
    /// and clears the value. Used by "Show in File Explorer" so a tab can route
    /// the user back to the tree even when the containing folders are collapsed.
    var pendingRevealPath: String?
    /// Saved vertical scroll offset for the detail pane, keyed by absolute file
    /// path. Lives here (not on `LiveFileContentView`) so the position survives
    /// the view being destroyed and rebuilt when the user switches tmux windows
    /// or sessions and returns to the same file.
    var scrollOffsets: [String: CGFloat] = [:]
    /// Monotonic counter bumped from outside the view (e.g., the Cmd-Shift-F
    /// menu command) to request the search field take keyboard focus. The view
    /// observes the value and drives `@FocusState` when it changes; using a
    /// counter (rather than a Bool) re-fires focus even when the field is
    /// already focused, so the user can re-trigger the shortcut to land back
    /// on the field after selecting a result.
    var searchFieldFocusRequest = 0
}

/// Open-file-tab state scoped to a tmux session, so tabs and selection survive
/// switches between windows in the same session.
@Observable
@MainActor
final class SessionFileTabsState {
    /// Files opened as their own tabs via the "Open in New Tab" context menu.
    var openFileTabs: [OpenFileTab] = []
    /// When non-nil, the content area shows this file tab instead of the tree
    /// or terminal.
    var selectedFileTabId: UUID?
    /// Saved vertical scroll offset per open file tab. Lives here (not on
    /// `OpenFileTab` itself) so the `LiveFileContentView` can read/write the
    /// position via a stable binding while the tab struct stays a value type.
    /// Without this, switching tmux windows or sessions and returning would
    /// destroy and rebuild the file content view, dropping the user back to
    /// the top of the file.
    var scrollOffsets: [UUID: CGFloat] = [:]
}

/// A draggable vertical divider for resizing adjacent views.
private struct ResizableDivider: View {
    @Binding var dimension: CGFloat
    let minDimension: CGFloat
    let maxDimension: CGFloat

    @State private var isDragging = false
    @State private var initialDimension: CGFloat = 0
    @State private var isCursorPushed = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color.gray.opacity(0.3))
            .frame(width: 4)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                    isCursorPushed = true
                } else {
                    NSCursor.pop()
                    isCursorPushed = false
                }
            }
            .onDisappear {
                if isCursorPushed {
                    NSCursor.pop()
                    isCursorPushed = false
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            initialDimension = dimension
                        }
                        let newWidth = initialDimension + value.translation.width
                        dimension = min(max(newWidth, minDimension), maxDimension)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

/// Displays a file tree navigator for a directory with an editor pane for the selected file.
/// Modeled after the NavigatorDemo in the ProjectNavigator package.
struct FileBrowserView: View {
    let directoryPath: String
    @Bindable var state: FileBrowserState
    /// Session-scoped tab strip. Updated here only to refresh deletion flags
    /// for tabs whose file lives under `directoryPath`.
    @Bindable var sessionTabs: SessionFileTabsState
    /// Called when the user picks "Open in New Tab" on a file in the context menu.
    let onOpenFileInNewTab: (String) -> Void

    @Dependency(FileSystemLoadingService.self) private var fileSystemService
    @Dependency(FileTextSearchService.self) private var textSearchService

    @State private var loadTreeTask: Task<Void, Never>?
    @State private var contentSearchTask: Task<Void, Never>?
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        if let viewState = state.viewState {
            loadedContent(viewState: viewState)
                .task(id: directoryPath) {
                    if state.loadedPath != directoryPath {
                        await loadTree()
                    }
                    if state.allFilesDirectoryPath != directoryPath {
                        state.allFiles = []
                        state.allFilesDirectoryPath = directoryPath
                        for await batch in fileSystemService.collectAllFiles(
                            URL(fileURLWithPath: directoryPath)
                        ) {
                            state.allFiles.append(contentsOf: batch)
                        }
                        // Only after the initial collection finishes do we know which
                        // files actually exist; calling this mid-stream would wrongly
                        // flag tabs as deleted against a partial allFiles snapshot.
                        refreshOpenFileTabDeletionState()
                    }
                }
                .task(id: state.loadedFolderPaths) {
                    var watchedPaths = state.loadedFolderPaths
                    watchedPaths.insert(directoryPath)
                    for await _ in fileSystemService.directoryChanges(watchedPaths) {
                        await loadTree()
                        var refreshed: [FileSearchResult] = []
                        for await batch in fileSystemService.collectAllFiles(
                            URL(fileURLWithPath: directoryPath)
                        ) {
                            refreshed.append(contentsOf: batch)
                        }
                        state.allFiles = refreshed
                        refreshOpenFileTabDeletionState()
                    }
                }
                .onChange(of: viewState.expansions) {
                    handleExpansionChange(viewState: viewState)
                }
                .task(id: state.pendingRevealPath) {
                    await revealPendingPathIfNeeded()
                }
                .task(id: state.searchFieldFocusRequest) {
                    await applySearchFieldFocusIfRequested()
                }
                .onDisappear {
                    // Content searches can spawn a `git ls-files` process and
                    // walk the tree reading text files; if the user navigates
                    // away mid-search there's no reason to keep going. Clear
                    // the running flag here too — once the task is cancelled,
                    // its `state.isContentSearchRunning = false` line at the
                    // tail won't run, which would otherwise leave the search
                    // results list stuck on the "Searching..." spinner if the
                    // user came back without typing a new query.
                    contentSearchTask?.cancel()
                    state.isContentSearchRunning = false
                }
        } else {
            ProgressView("Loading files...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: directoryPath) {
                    await loadTree()
                }
        }
    }

    private func loadTree() async {
        let result = await fileSystemService.loadFileTree(
            URL(fileURLWithPath: directoryPath),
            state.loadedFolderPaths,
            state.stableIds
        )
        if let existing = state.viewState {
            // Mutate the existing FileTree in place so `File.Proxy`'s weak
            // reference to the tree stays valid and ProjectNavigator sees the
            // new children. Then rebuild the `FileNavigatorViewState` around
            // the same tree so SwiftUI sees `state.viewState` change and
            // rebuilds the navigator hierarchy — mutating `fileTree.root`
            // alone does not reliably propagate through the navigator's
            // disclosure views, so expansions load one step behind.
            existing.fileTree.root = result.root.proxy(within: existing.fileTree)
            state.viewState = FileNavigatorViewState<TextFileContents>(
                fileTree: existing.fileTree,
                expansions: existing.expansions,
                selection: existing.selection
            )
        } else {
            let tree = FileTree(files: result.root)
            state.viewState = FileNavigatorViewState<TextFileContents>(
                fileTree: tree,
                expansions: WrappedUUIDSet(),
                selection: nil
            )
        }
        state.loadedPath = directoryPath
        state.stableIds = result.stableIds
        state.loadedFolderPaths = result.loadedFolderPaths
        state.symlinkedPaths = result.symlinkedPaths

        // Clear the selection if the previously selected path no longer exists
        // in the rebuilt tree; otherwise `fileDetailView` would render against
        // a stale UUID that `ProjectNavigator` no longer knows about.
        if
            let existing = state.viewState,
            let sel = existing.selection,
            state.reverseIds[sel] == nil {
            existing.selection = nil
        }
    }

    /// Routes the visible content based on session-level tab selection. If a file
    /// tab is selected, that file's contents render here while the tree itself
    /// stays mounted underneath so its `directoryChanges` task keeps refreshing
    /// `allFiles` (and therefore the tabs' deletion state).
    @ViewBuilder
    private func loadedContent(
        viewState: FileNavigatorViewState<TextFileContents>
    ) -> some View {
        if
            let selectedTabId = sessionTabs.selectedFileTabId,
            let tab = sessionTabs.openFileTabs.first(where: { $0.id == selectedTabId }) {
            OpenFileTabContentView(tab: tab, sessionTabs: sessionTabs)
        } else {
            fileBrowserContent(viewState: viewState)
        }
    }

    /// Marks open file tabs whose underlying file is no longer present in `allFiles`
    /// as deleted, and clears the flag for tabs whose files came back (e.g., restored).
    /// Only tabs originating from this view's directory are evaluated, so tabs opened
    /// from a different directory aren't falsely flagged when the user is viewing
    /// another window's tree.
    private func refreshOpenFileTabDeletionState() {
        guard !sessionTabs.openFileTabs.isEmpty else { return }
        let existingPaths = Set(state.allFiles.map(\.fullPath))
        let dirPrefix = directoryPath + "/"
        for index in sessionTabs.openFileTabs.indices {
            let tab = sessionTabs.openFileTabs[index]
            guard tab.path.hasPrefix(dirPrefix) else { continue }
            let shouldBeDeleted = !existingPaths.contains(tab.path)
            if tab.isDeleted != shouldBeDeleted {
                sessionTabs.openFileTabs[index].isDeleted = shouldBeDeleted
                if shouldBeDeleted {
                    sessionTabs.scrollOffsets.removeValue(forKey: tab.id)
                }
            }
        }
    }

    /// Drives `@FocusState` when an external caller bumps
    /// `state.searchFieldFocusRequest`. The first run (request == 0) is a
    /// no-op — `.task(id:)` always fires once on mount, but we only want to
    /// steal focus when something actually requested it. The brief sleep gives
    /// SwiftUI a tick to insert a freshly-mounted TextField into the responder
    /// chain before we ask it to become first responder; otherwise the focus
    /// request lands on a non-existent field and is silently dropped.
    private func applySearchFieldFocusIfRequested() async {
        guard state.searchFieldFocusRequest > 0 else { return }
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }
        isSearchFieldFocused = true
    }

    /// Reveals `state.pendingRevealPath` by loading and expanding each ancestor
    /// folder, then selects the leaf. Clears the pending value when done so the
    /// task only fires once per request.
    private func revealPendingPathIfNeeded() async {
        guard let target = state.pendingRevealPath else { return }
        defer { state.pendingRevealPath = nil }
        guard target.hasPrefix(directoryPath + "/") else { return }

        let relative = String(target.dropFirst(directoryPath.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return }

        var ancestor = directoryPath
        var ancestorPaths: [String] = []
        for part in parts.dropLast() {
            ancestor += "/" + part
            ancestorPaths.append(ancestor)
        }

        var needsLoad = false
        for path in ancestorPaths where !state.loadedFolderPaths.contains(path) {
            state.loadedFolderPaths.insert(path)
            needsLoad = true
        }
        if needsLoad {
            loadTreeTask?.cancel()
            await loadTree()
        }

        for path in ancestorPaths {
            if let id = state.stableIds[path] {
                state.viewState?.expansions[id] = true
            }
        }

        if let leafId = state.stableIds[target] {
            state.viewState?.selection = leafId
        }
    }

    /// Detects when the user expands a folder whose children haven't been loaded yet,
    /// and triggers a tree rebuild with that folder's contents. Cancels any in-flight
    /// reload so rapid expansions don't queue overlapping `loadTree()` calls.
    private func handleExpansionChange(viewState: FileNavigatorViewState<TextFileContents>) {
        for expandedId in viewState.expansions.ids {
            guard let path = state.reverseIds[expandedId] else { continue }
            guard !state.loadedFolderPaths.contains(path) else { continue }

            // This folder needs its children loaded
            state.loadedFolderPaths.insert(path)
            loadTreeTask?.cancel()
            loadTreeTask = Task {
                await loadTree()
            }
            return
        }
    }

    // MARK: - File Search

    private var fileSearchField: some View {
        HStack(spacing: 6) {
            Symbols.magnifyingglass.image
                .foregroundStyle(.secondary)
                .font(.caption)

            TextField(
                state.searchMode == .name ? "Search files..." : "Search file contents...",
                text: $state.searchQuery
            )
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($isSearchFieldFocused)
            .accessibilityLabel(state.searchMode == .name ? "Search files" : "Search file contents")

            if !state.searchQuery.isEmpty {
                Button {
                    state.searchQuery = ""
                    state.selectedSearchPath = nil
                    state.selectedContentSearchMatchID = nil
                } label: {
                    Symbols.xmarkCircleFill.image
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            // Compact segmented picker on the same row as the search field so
            // adding a content-search mode doesn't grow the search bar's
            // vertical footprint and squeeze rows out of the file tree.
            Picker("Search mode", selection: $state.searchMode) {
                Text("Name").tag(FileSearchMode.name)
                Text("Content").tag(FileSearchMode.content)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 110)
            .accessibilityLabel("Search mode")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Recomputes the cached search results from the current `searchQuery` and
    /// `state.allFiles`. Called via `.onChange` so we don't fuzzy-match thousands
    /// of files on every SwiftUI render pass.
    private func recomputeSearchResults() {
        guard !state.searchQuery.isEmpty else {
            state.cachedSearchResults = []
            return
        }
        let query = state.searchQuery

        state.cachedSearchResults = Array(
            state.allFiles
                .compactMap { result -> (FileSearchResult, Int)? in
                    guard result.relativePath.fuzzyMatches(query) else { return nil }
                    return (result, result.name.fileSearchScore(for: query))
                }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return lhs.0.relativePath.count < rhs.0.relativePath.count
                }
                .prefix(100)
                .map(\.0)
        )
    }

    /// Cancels any in-flight content search and starts a new one for the
    /// current `searchQuery`. Streamed batches accumulate into
    /// `cachedContentSearchResults` as they arrive.
    private func recomputeContentSearchResults() {
        contentSearchTask?.cancel()
        guard !state.searchQuery.isEmpty else {
            state.cachedContentSearchResults = []
            state.isContentSearchRunning = false
            state.selectedContentSearchMatchID = nil
            return
        }
        let query = state.searchQuery
        let directoryURL = URL(fileURLWithPath: directoryPath)
        state.cachedContentSearchResults = []
        state.selectedContentSearchMatchID = nil
        state.isContentSearchRunning = true
        contentSearchTask = Task { @MainActor in
            // Small debounce so rapid keystrokes don't spawn searches we'd
            // immediately throw away. The cancellation above already handles
            // the live-typing case; this just keeps things calm if a new task
            // was started before its predecessor was cancelled.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            for await batch in textSearchService.searchFileContents(directoryURL, query) {
                guard !Task.isCancelled else { return }
                guard state.searchQuery == query else { return }
                state.cachedContentSearchResults.append(contentsOf: batch)
            }
            guard !Task.isCancelled else { return }
            state.isContentSearchRunning = false
        }
    }

    @ViewBuilder
    private var fileSearchResultsList: some View {
        if state.cachedSearchResults.isEmpty {
            ContentUnavailableView.search(text: state.searchQuery)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $state.selectedSearchPath) {
                ForEach(state.cachedSearchResults) { result in
                    searchResultRow(result)
                        .tag(result.fullPath)
                        .fileContextMenu(
                            fullPath: result.fullPath,
                            directoryPath: directoryPath,
                            isDirectory: false,
                            onOpenFileInNewTab: onOpenFileInNewTab
                        )
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var contentSearchResultsList: some View {
        if state.cachedContentSearchResults.isEmpty {
            if state.isContentSearchRunning {
                ProgressView("Searching...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: state.searchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List(selection: $state.selectedContentSearchMatchID) {
                ForEach(state.cachedContentSearchResults) { match in
                    contentSearchResultRow(match)
                        .tag(match.id)
                        .fileContextMenu(
                            fullPath: match.fullPath,
                            directoryPath: directoryPath,
                            isDirectory: false,
                            onOpenFileInNewTab: onOpenFileInNewTab
                        )
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    /// Returns the directory portion of a relative path (everything before the
    /// final slash), or `""` if the path has no directory component. Used by
    /// both result-row builders to render the dimmed parent-folder hint under
    /// the file name.
    private func directorySegment(of relativePath: String) -> String {
        guard let lastSlash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<lastSlash])
    }

    @ViewBuilder
    private func searchResultRow(_ result: FileSearchResult) -> some View {
        let directory = directorySegment(of: result.relativePath)

        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(result.name)
                    .font(.callout)
                    .lineLimit(1)
            } icon: {
                Symbols.docPlaintextFill.image
                    .foregroundStyle(.secondary)
            }

            if !directory.isEmpty {
                Text(directory)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder
    private func contentSearchResultRow(_ match: FileTextSearchMatch) -> some View {
        let directory = directorySegment(of: match.relativePath)

        VStack(alignment: .leading, spacing: 2) {
            Label {
                // The HStack carries a combined accessibility label so
                // VoiceOver reads "main.swift, line 6" as one element instead
                // of two ("main.swift", pause, ":6").
                HStack(spacing: 4) {
                    Text(match.name)
                        .font(.callout)
                        .lineLimit(1)
                    Text(":\(match.lineNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(match.name), line \(match.lineNumber)")
            } icon: {
                Symbols.docPlaintextFill.image
                    .foregroundStyle(.secondary)
            }

            if !directory.isEmpty {
                Text(directory)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 24)
            }

            Text(match.lineText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.leading, 24)
                .accessibilityLabel("Match line: \(match.lineText)")
        }
    }

    // MARK: - File Browser Content

    private func fileRowLabel(name: String, itemId: UUID, isSymlink: Bool) -> some View {
        Label {
            Text(name)
                .font(.callout)
                .italic(isSymlink)
        } icon: {
            symlinkBadgedIcon(
                Symbols.docPlaintextFill.image.foregroundStyle(.secondary),
                isSymlink: isSymlink
            )
        }
        .fileContextMenu(
            fullPath: state.reverseIds[itemId],
            directoryPath: directoryPath,
            isDirectory: false,
            onOpenFileInNewTab: onOpenFileInNewTab
        )
    }

    private func folderRowLabel(name: String, itemId: UUID, isSymlink: Bool) -> some View {
        Label {
            Text(name)
                .font(.callout)
                .italic(isSymlink)
        } icon: {
            symlinkBadgedIcon(
                Symbols.folderFill.image.foregroundStyle(.blue),
                isSymlink: isSymlink
            )
        }
        .fileContextMenu(
            fullPath: state.reverseIds[itemId],
            directoryPath: directoryPath,
            isDirectory: true,
            onOpenFileInNewTab: onOpenFileInNewTab
        )
    }

    /// Overlays a small filled-link badge on the bottom-trailing corner of an icon
    /// so symlinks read as their target type (file vs. folder) while still being
    /// visibly distinguishable from regular entries.
    private func symlinkBadgedIcon(_ content: some View, isSymlink: Bool) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if isSymlink {
                Symbols.linkCircleFill.image
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white, .blue)
                    .symbolRenderingMode(.palette)
                    .offset(x: 3, y: 2)
            }
        }
    }

    private func isSymlinked(_ itemId: UUID) -> Bool {
        guard let path = state.reverseIds[itemId] else { return false }
        return state.symlinkedPaths.contains(path)
    }

    @ViewBuilder
    private func fileBrowserContent(
        viewState: FileNavigatorViewState<TextFileContents>
    ) -> some View {
        @Bindable var bindableState = viewState

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                fileSearchField
                Divider()

                if state.searchQuery.isEmpty {
                    List(selection: $bindableState.selection) {
                        FileNavigator(
                            name: nil as String?,
                            item: .constant(viewState.fileTree.root),
                            parent: .constant(nil),
                            viewState: viewState,
                            linkLabel: { _, _, _ in
                                // Our loader resolves symlinks into .file or .folder entries
                                // (so symlinked folders stay expandable), so .link entries
                                // never reach this closure. Symlink rendering is handled by
                                // fileLabel / folderLabel via state.symlinkedPaths.
                                EmptyView()
                            },
                            fileLabel: { cursor, _, proxy in
                                fileRowLabel(
                                    name: cursor.name,
                                    itemId: proxy.id,
                                    isSymlink: isSymlinked(proxy.id)
                                )
                            },
                            folderLabel: { cursor, _, folder in
                                folderRowLabel(
                                    name: cursor.name,
                                    itemId: folder.wrappedValue.id,
                                    isSymlink: isSymlinked(folder.wrappedValue.id)
                                )
                            }
                        )
                        .navigatorFilter { !skippedNavigatorEntries.contains($0) }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                } else {
                    switch state.searchMode {
                    case .name:
                        fileSearchResultsList
                    case .content:
                        contentSearchResultsList
                    }
                }
            }
            .frame(width: state.sidebarWidth)

            ResizableDivider(dimension: $state.sidebarWidth, minDimension: 150, maxDimension: 400)

            fileDetailView(viewState: viewState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: state.searchQuery, initial: true) {
            switch state.searchMode {
            case .name:
                recomputeSearchResults()
            case .content:
                recomputeContentSearchResults()
            }
        }
        .onChange(of: state.searchMode) {
            // Selection clears on mode switch — the two modes use different
            // selection stores, and a content-search selection has no meaning
            // in the file-name list (and vice versa).
            state.selectedSearchPath = nil
            state.selectedContentSearchMatchID = nil
            switch state.searchMode {
            case .name:
                contentSearchTask?.cancel()
                state.cachedContentSearchResults = []
                state.isContentSearchRunning = false
                recomputeSearchResults()
            case .content:
                state.cachedSearchResults = []
                recomputeContentSearchResults()
            }
        }
        .onChange(of: state.allFiles) {
            if state.searchMode == .name {
                recomputeSearchResults()
            }
        }
        .onChange(of: state.cachedSearchResults) {
            // Drop the selection if the previously selected file is no longer
            // in the visible result set.
            if
                let selected = state.selectedSearchPath,
                !state.cachedSearchResults.contains(where: { $0.fullPath == selected }) {
                state.selectedSearchPath = nil
            }
        }
        .onChange(of: state.cachedContentSearchResults) {
            // Fires once per streaming batch, so cheap-path-out when there's
            // nothing selected — that's the common case while results stream
            // in (the user can't pick a row that doesn't exist yet).
            guard let selected = state.selectedContentSearchMatchID else { return }
            if !state.cachedContentSearchResults.contains(where: { $0.id == selected }) {
                state.selectedContentSearchMatchID = nil
            }
        }
    }

    @ViewBuilder
    private func fileDetailView(
        viewState: FileNavigatorViewState<TextFileContents>
    ) -> some View {
        if !state.searchQuery.isEmpty {
            if let path = selectedSearchResultPath {
                let relativePath = path.hasPrefix(directoryPath + "/")
                    ? String(path.dropFirst(directoryPath.count + 1))
                    : URL(fileURLWithPath: path).lastPathComponent
                let directoryName = URL(fileURLWithPath: directoryPath).lastPathComponent

                VStack(alignment: .leading, spacing: 0) {
                    Text(directoryName + "/" + relativePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(8)
                    Divider()
                    LiveFileContentView(filePath: path, scrollOffsetY: scrollBinding(for: path))
                }
            } else {
                let title = state.searchMode == .name ? "Search for Files" : "Search File Contents"
                let description = state.searchMode == .name
                    ? "Type a file name to search, then select a result to view."
                    : "Type to search inside files, then select a result to view."
                ContentUnavailableView(
                    title,
                    symbol: .magnifyingglass,
                    description: description
                )
            }
        } else if
            let uuid = viewState.selection,
            viewState.fileTree.proxy(for: uuid).file != nil {
            let filePath = viewState.fileTree.filePath(of: uuid)
            let fullFilePath = filePath.map { directoryPath + "/" + $0.string }

            VStack(alignment: .leading, spacing: 0) {
                // File path header
                if let filePath {
                    let directoryName = URL(fileURLWithPath: directoryPath).lastPathComponent
                    Text(directoryName + "/" + filePath.string)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(8)
                    Divider()
                }

                if let fullFilePath {
                    LiveFileContentView(filePath: fullFilePath, scrollOffsetY: scrollBinding(for: fullFilePath))
                } else {
                    ContentUnavailableView(
                        "Unable to Read File",
                        symbol: .docPlaintextFill,
                        description: "This file could not be read as text."
                    )
                }
            }
        } else if
            let uuid = viewState.selection,
            viewState.fileTree.proxy(for: uuid).file == nil {
            // A folder is selected
            ContentUnavailableView(
                "Folder Selected",
                symbol: .folder,
                description: "Select a file to view its contents."
            )
        } else {
            ContentUnavailableView(
                "Select a File",
                symbol: .docPlaintextFill,
                description: "Choose a file from the navigator to view its contents."
            )
        }
    }

    private func scrollBinding(for path: String) -> Binding<CGFloat> {
        Binding(
            get: { state.scrollOffsets[path] ?? 0 },
            set: { state.scrollOffsets[path] = $0 }
        )
    }

    /// Resolves the currently-selected search result to its file path,
    /// regardless of which search mode is active.
    private var selectedSearchResultPath: String? {
        switch state.searchMode {
        case .name:
            return state.selectedSearchPath
        case .content:
            guard let id = state.selectedContentSearchMatchID else { return nil }
            return state.cachedContentSearchResults.first(where: { $0.id == id })?.fullPath
        }
    }
}

// MARK: - Open File Tab Content View

/// The content view shown when the user selects an open file tab.
/// Renders the file's path header + live content, or a "file deleted" placeholder.
struct OpenFileTabContentView: View {
    let tab: OpenFileTab
    /// Source of truth for the saved scroll offset so it persists when the
    /// view is destroyed and rebuilt (window/session switches).
    let sessionTabs: SessionFileTabsState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pathHeader
            Divider()
            if tab.isDeleted {
                ContentUnavailableView(
                    "File Deleted",
                    symbol: .docPlaintextFill,
                    description: "The file \(tab.name) has been removed from disk."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LiveFileContentView(filePath: tab.path, scrollOffsetY: scrollBinding)
            }
        }
    }

    private var scrollBinding: Binding<CGFloat> {
        Binding(
            get: { sessionTabs.scrollOffsets[tab.id] ?? 0 },
            set: { sessionTabs.scrollOffsets[tab.id] = $0 }
        )
    }

    private var pathHeader: some View {
        let directoryPath = tab.directoryPath
        let relativePath = tab.path.hasPrefix(directoryPath + "/")
            ? String(tab.path.dropFirst(directoryPath.count + 1))
            : tab.name
        let directoryName = URL(fileURLWithPath: directoryPath).lastPathComponent
        return Text(directoryName + "/" + relativePath)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(8)
    }
}

// MARK: - Live File Content View

/// Displays a file's contents and monitors it for changes on disk.
///
/// `scrollOffsetY` is an optional binding owned by the parent (e.g. an open
/// file tab). When provided, the markdown and text viewers persist their
/// scroll position through it so closing/reopening a tab — or switching tmux
/// windows or sessions — restores the previous scroll position. When `nil`
/// (e.g. the file detail pane backed by tree selection) the viewers fall back
/// to local `@State`, matching the original ephemeral behaviour.
private struct LiveFileContentView: View {
    let filePath: String
    var scrollOffsetY: Binding<CGFloat>?

    @Dependency(FileSystemLoadingService.self) private var fileSystemService

    @State private var kind: FileContentKind = .unsupported
    @State private var text: String?
    @State private var nsImage: NSImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch kind {
                case .image:
                    if let nsImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                    }
                case .pdf:
                    PDFViewRepresentable(
                        url: fileSystemService.resolveFileURL(filePath) ?? URL(fileURLWithPath: filePath),
                        savedScrollY: scrollOffsetY
                    )
                case .video:
                    AVPlayerViewRepresentable(url: fileSystemService.resolveFileURL(filePath) ?? URL(fileURLWithPath: filePath))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .html:
                    if #available(macOS 26, *) {
                        ScrollableWebView(
                            url: fileSystemService.resolveFileURL(filePath) ?? URL(fileURLWithPath: filePath),
                            savedScrollY: scrollOffsetY
                        )
                    }
                case .markdown:
                    if let text {
                        MarkdownContentView(text: text, savedScrollY: scrollOffsetY)
                    }
                case .text:
                    if let text {
                        PlainTextContentView(text: text, savedScrollY: scrollOffsetY)
                    }
                case .unsupported:
                    ContentUnavailableView(
                        "Unable to Read File",
                        symbol: .docPlaintextFill,
                        description: "This file could not be read as text."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: filePath) {
            isLoading = true
            await loadContent()
            isLoading = false
            for await _ in fileSystemService.fileChanges(filePath) {
                await loadContent()
            }
        }
    }

    private func loadContent() async {
        kind = fileSystemService.detectFileKind(filePath)
        // Clear all state first
        text = nil
        nsImage = nil

        switch kind {
        case .image:
            nsImage = await fileSystemService.readImageFile(filePath)
        case .markdown,
             .text:
            text = await fileSystemService.readTextFile(filePath)
            if text == nil { kind = .unsupported }
        case .pdf,
             .video,
             .html:
            break // Handled natively by their views
        case .unsupported:
            break
        }
    }
}

/// Wraps PDFKit's PDFView for use in SwiftUI.
///
/// `savedScrollY` is an optional binding that — when set — drives scroll
/// preservation across view rebuilds. PDFView owns its own `NSScrollView`, so
/// we observe the inner clip view's bounds for user scrolls and write back to
/// the binding, then re-apply the saved offset whenever the document is
/// (re)loaded. The `isRestoring` gate prevents the programmatic restore from
/// rebroadcasting through the same observer and clobbering the saved value.
private struct PDFViewRepresentable: NSViewRepresentable {
    let url: URL
    var savedScrollY: Binding<CGFloat>?

    @MainActor
    final class Coordinator {
        var savedScrollY: Binding<CGFloat>?
        var isRestoring = false
        var observer: NSObjectProtocol?
        weak var observedClipView: NSClipView?
        /// Handle for the in-flight `attachAndRestore` task so its lifetime
        /// is tied to the view's. Without this, the retry loop (up to ~500ms)
        /// keeps running after `dismantleNSView` and writes into a binding
        /// whose owner may be gone.
        var attachTask: Task<Void, Never>?

        func detachObserver() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            observedClipView = nil
            attachTask?.cancel()
            attachTask = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        context.coordinator.savedScrollY = savedScrollY
        attachAndRestore(view: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        context.coordinator.savedScrollY = savedScrollY
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
            context.coordinator.detachObserver()
            attachAndRestore(view: nsView, coordinator: context.coordinator)
        }
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.detachObserver()
    }

    /// Waits one runloop tick for PDFView to lay out its inner scroll view,
    /// then attaches the bounds observer and restores the saved Y. Both steps
    /// have to wait — accessing `documentView.enclosingScrollView` immediately
    /// after assigning the document returns nil because layout hasn't run yet.
    /// The task handle is stored on the coordinator so `detachObserver` /
    /// `dismantleNSView` can cancel the retry loop when the view goes away.
    private func attachAndRestore(view: PDFView, coordinator: Coordinator) {
        coordinator.attachTask?.cancel()
        coordinator.attachTask = Task { @MainActor [weak coordinator] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let coordinator, !Task.isCancelled else { return }
            guard let scrollView = view.documentView?.enclosingScrollView else { return }
            attachObserver(scrollView: scrollView, coordinator: coordinator)
            await restoreScroll(scrollView: scrollView, coordinator: coordinator)
        }
    }

    private func attachObserver(scrollView: NSScrollView, coordinator: Coordinator) {
        let clip = scrollView.contentView
        guard coordinator.observedClipView !== clip else { return }
        coordinator.detachObserver()
        clip.postsBoundsChangedNotifications = true
        coordinator.observedClipView = clip
        coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: nil
        ) { [weak coordinator, weak clip] _ in
            // Posted synchronously from the main thread; safe to read state and
            // write the binding without dispatching.
            MainActor.assumeIsolated {
                guard let coordinator, let clip else { return }
                guard !coordinator.isRestoring else { return }
                coordinator.savedScrollY?.wrappedValue = clip.bounds.origin.y
            }
        }
    }

    /// Re-applies the saved scroll Y until the clip view actually lands on
    /// (or near) the target. PDFView grows its documentView asynchronously
    /// after the document is assigned, so a single `scroll(to:)` can clamp
    /// to a smaller value when the saved offset is near the bottom of the
    /// document and the content hasn't finished laying out yet. Looping
    /// catches the eventual growth without depending on a hand-tuned sleep.
    private func restoreScroll(scrollView: NSScrollView, coordinator: Coordinator) async {
        guard let target = coordinator.savedScrollY?.wrappedValue, target > 0 else { return }
        coordinator.isRestoring = true
        defer { coordinator.isRestoring = false }
        for _ in 0..<10 {
            if Task.isCancelled { return }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            if abs(scrollView.contentView.bounds.origin.y - target) < 1 { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Renders an HTML file in a SwiftUI `WebView` while preserving its vertical
/// scroll offset across view rebuilds.
///
/// `savedScrollY` is an optional binding that drives the initial scroll
/// position and receives updates as the user scrolls. The `isTrackingUserScroll`
/// gate suppresses notifications fired during the initial layout so the
/// pre-restore offset doesn't overwrite the saved value with 0.
@available(macOS 26, *)
private struct ScrollableWebView: View {
    let url: URL
    var savedScrollY: Binding<CGFloat>?

    @State private var position = ScrollPosition()
    @State private var localScrollY: CGFloat = 0
    @State private var isTrackingUserScroll = false

    private var scrollY: Binding<CGFloat> {
        savedScrollY ?? $localScrollY
    }

    var body: some View {
        WebView(url: url)
            .webViewScrollPosition($position)
            .webViewOnScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newValue in
                guard isTrackingUserScroll else { return }
                scrollY.wrappedValue = newValue
            }
            .task(id: url) {
                // The web content loads asynchronously, so the scroll view's
                // contentSize starts at 0 and grows as HTML/CSS resolves.
                // Wait for layout to settle before applying the saved offset
                // (otherwise WebView clamps the target to a tiny content size)
                // and then re-enable user-scroll tracking.
                let target = scrollY.wrappedValue
                isTrackingUserScroll = false
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                position.scrollTo(y: target)
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                isTrackingUserScroll = true
            }
    }
}

/// Wraps AVKit's AVPlayerView for use in SwiftUI.
private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if (nsView.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            nsView.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

/// Renders markdown with `StructuredText` inside a `ScrollView`.
///
/// Workaround for https://github.com/gonzalezreal/textual/issues/49: Textual's selection
/// overlay uses preference-driven geometry that isn't coherent on first layout inside a
/// SwiftUI `ScrollView`, so selection only becomes live after the user manually scrolls.
/// The `.task` reproduces that scroll: when restoring to a non-zero saved offset, the
/// scroll-to-target itself is enough; when the target is zero, we nudge to 4 and back
/// so the offset actually moves. The `minHeight` pegged to the container guarantees the
/// content is always taller than the viewport so the zero-target nudge has somewhere to
/// go — even for markdown short enough to fit without scrolling. Remove this dance once
/// the upstream issue is fixed.
///
/// `savedScrollY` is an optional binding owned by an open file tab. When set, the view
/// restores its scroll position from the binding on first appearance and updates it on
/// every user scroll, so switching tabs/sessions and returning preserves the position.
/// When `nil`, an internal `@State` provides ephemeral storage and the original
/// "always start at the top" behaviour applies.
private struct MarkdownContentView: View {
    let text: String
    var savedScrollY: Binding<CGFloat>?

    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var localScrollY: CGFloat = 0
    /// Set to `true` after the initial restore completes. Until then, scroll
    /// notifications from layout/restore are ignored so they don't overwrite
    /// the saved offset with intermediate values (0 → nudge → restore).
    @State private var isTrackingUserScroll = false

    private var scrollY: Binding<CGFloat> {
        savedScrollY ?? $localScrollY
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                StructuredText(markdown: text)
                    .padding()
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height + 8,
                        alignment: .topLeading
                    )
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { proxy in
                proxy.contentOffset.y
            } action: { _, newValue in
                guard isTrackingUserScroll else { return }
                scrollY.wrappedValue = newValue
            }
            .textual.textSelection(.enabled)
            .task(id: text) {
                // Capture the saved offset before the initial layout fires
                // any scroll notifications. For a non-zero target, the
                // scroll itself activates the Textual selection overlay; for
                // a zero target we nudge to 4 first, then settle on 0.
                //
                // Reset the tracking gate first: when `text` changes (file
                // edited on disk → re-read), the flag is still `true` from
                // the previous run, so layout-driven scroll events would
                // clobber the saved offset before `scrollTo` runs.
                let target = scrollY.wrappedValue
                isTrackingUserScroll = false
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                if target == 0 {
                    scrollPosition.scrollTo(y: 4)
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled else { return }
                    scrollPosition.scrollTo(y: 0)
                } else {
                    scrollPosition.scrollTo(y: target)
                }
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                isTrackingUserScroll = true
            }
        }
    }
}

/// Renders plain monospaced text in a `ScrollView` with selection enabled.
///
/// `savedScrollY` is an optional binding owned by an open file tab. When set,
/// the view restores its scroll position from the binding on first appearance
/// and updates it on every user scroll, so switching tabs/sessions and
/// returning preserves the position. When `nil`, an internal `@State` provides
/// ephemeral storage.
///
/// Trade-off vs. `TextEditor`/`NSTextView`: there's no native cmd-F find bar,
/// and `Text` lays out the entire string up-front (so very large files render
/// slower than `NSTextView`'s glyph-range layout would).
private struct PlainTextContentView: View {
    let text: String
    var savedScrollY: Binding<CGFloat>?

    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var localScrollY: CGFloat = 0
    /// Set to `true` after the initial restore completes. Until then, scroll
    /// notifications from layout/restore are ignored so they don't overwrite
    /// the saved offset with intermediate values (0 → restore).
    @State private var isTrackingUserScroll = false

    private var scrollY: Binding<CGFloat> {
        savedScrollY ?? $localScrollY
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding()
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { proxy in
            proxy.contentOffset.y
        } action: { _, newValue in
            guard isTrackingUserScroll else { return }
            scrollY.wrappedValue = newValue
        }
        .task(id: text) {
            // Wait for the initial layout to produce a real content size
            // before scrolling; doing this synchronously would clamp to 0
            // because the Text hasn't measured itself yet.
            //
            // Reset the tracking gate first: when `text` changes (file
            // edited on disk → re-read), the flag is still `true` from the
            // previous run, so layout-driven scroll events would clobber
            // the saved offset before `scrollTo` runs.
            let target = scrollY.wrappedValue
            isTrackingUserScroll = false
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            scrollPosition.scrollTo(y: target)
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            isTrackingUserScroll = true
        }
    }
}
