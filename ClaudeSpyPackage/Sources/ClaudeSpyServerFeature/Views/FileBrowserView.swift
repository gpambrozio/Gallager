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

/// One file's worth of content-search matches, used by the grouped results
/// list. Identified by `fullPath` so SwiftUI can preserve disclosure state
/// across streaming batches (each batch arrives, the array gets re-bucketed,
/// but the same path keeps the same identity).
struct ContentSearchGroup: Identifiable {
    var id: String { fullPath }
    let fullPath: String
    let relativePath: String
    let name: String
    var matches: [FileTextSearchMatch]
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
    /// Full paths of content-search file groups the user has manually
    /// collapsed. New files default to expanded (a path absent from this set
    /// is shown open) so streaming results stay visible without an extra
    /// click; tracking *collapsed* state preserves user intent across
    /// streaming batches without requiring us to write into the set every
    /// time a new file appears in the results.
    var collapsedContentSearchFiles: Set<String> = []
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
        let groups = contentSearchGroups
        if groups.isEmpty {
            if state.isContentSearchRunning {
                ProgressView("Searching...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: state.searchQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List(selection: $state.selectedContentSearchMatchID) {
                ForEach(groups) { group in
                    DisclosureGroup(isExpanded: groupExpansionBinding(group)) {
                        ForEach(group.matches) { match in
                            contentSearchMatchRow(match)
                                .tag(match.id)
                                .fileContextMenu(
                                    fullPath: match.fullPath,
                                    directoryPath: directoryPath,
                                    isDirectory: false,
                                    onOpenFileInNewTab: onOpenFileInNewTab
                                )
                        }
                    } label: {
                        contentSearchFileHeader(group)
                            .fileContextMenu(
                                fullPath: group.fullPath,
                                directoryPath: directoryPath,
                                isDirectory: false,
                                onOpenFileInNewTab: onOpenFileInNewTab
                            )
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    /// Buckets the streaming `cachedContentSearchResults` into per-file groups
    /// preserving first-occurrence order. Recomputed each render — the result
    /// is bounded by the search batch limits and the work is a single pass, so
    /// a cache here would just complicate invalidation.
    private var contentSearchGroups: [ContentSearchGroup] {
        var groups: [ContentSearchGroup] = []
        var indexByPath: [String: Int] = [:]
        for match in state.cachedContentSearchResults {
            if let i = indexByPath[match.fullPath] {
                groups[i].matches.append(match)
            } else {
                indexByPath[match.fullPath] = groups.count
                groups.append(ContentSearchGroup(
                    fullPath: match.fullPath,
                    relativePath: match.relativePath,
                    name: match.name,
                    matches: [match]
                ))
            }
        }
        return groups
    }

    /// Default-expanded binding: a path that's *not* in
    /// `collapsedContentSearchFiles` is shown open. Writing `false` adds the
    /// path; writing `true` removes it. Tracking only the user-collapsed set
    /// (rather than the expanded set) keeps default-expanded semantics for
    /// new files arriving in streaming batches without us having to mutate
    /// state on every batch.
    private func groupExpansionBinding(_ group: ContentSearchGroup) -> Binding<Bool> {
        Binding(
            get: { !state.collapsedContentSearchFiles.contains(group.fullPath) },
            set: { isExpanded in
                if isExpanded {
                    state.collapsedContentSearchFiles.remove(group.fullPath)
                } else {
                    state.collapsedContentSearchFiles.insert(group.fullPath)
                }
            }
        )
    }

    @ViewBuilder
    private func contentSearchFileHeader(_ group: ContentSearchGroup) -> some View {
        let directory = directorySegment(of: group.relativePath)
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name)
                        .font(.callout)
                        .lineLimit(1)
                    if !directory.isEmpty {
                        Text(directory)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Symbols.docPlaintextFill.image
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("\(group.matches.count)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                .accessibilityLabel("\(group.matches.count) matches")
        }
    }

    @ViewBuilder
    private func contentSearchMatchRow(_ match: FileTextSearchMatch) -> some View {
        HStack(spacing: 6) {
            Text(highlightedLine(match.lineText, query: state.searchQuery))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(match.lineNumber)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Line \(match.lineNumber): \(match.lineText)")
    }

    /// Builds an `AttributedString` that highlights every case-insensitive
    /// occurrence of `query` inside `text`. The highlight uses the system
    /// accent color at low opacity so it adapts to the user's chosen accent
    /// (Apple's pink/purple, blue, etc.) rather than a fixed yellow that
    /// might clash in dark mode.
    private func highlightedLine(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        let lowered = text.lowercased()
        let needle = query.lowercased()
        var cursor = lowered.startIndex
        while
            cursor < lowered.endIndex,
            let range = lowered.range(of: needle, range: cursor..<lowered.endIndex) {
            if let attRange = Range<AttributedString.Index>(range, in: attributed) {
                attributed[attRange].backgroundColor = Color.accentColor.opacity(0.35)
                attributed[attRange].foregroundColor = .primary
            }
            cursor = range.upperBound
        }
        return attributed
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
                    LiveFileContentView(
                        filePath: path,
                        scrollOffsetY: scrollBinding(for: path),
                        highlightLine: selectedContentSearchLine
                    )
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

    /// 1-based line number of the currently-selected content-search match,
    /// used to drive scroll-to-line in the detail pane. Nil for the name
    /// search list (those rows have no per-line semantics) and when no
    /// match is selected yet.
    private var selectedContentSearchLine: Int? {
        guard state.searchMode == .content else { return nil }
        guard let id = state.selectedContentSearchMatchID else { return nil }
        return state.cachedContentSearchResults.first(where: { $0.id == id })?.lineNumber
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
    /// Optional 1-based line number to highlight and scroll into view. Used
    /// by the content-search detail pane to surface the matched line; only
    /// honored by the plain-text branch since markdown/PDF/HTML rendering
    /// doesn't preserve line semantics.
    var highlightLine: Int?

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
                        PlainTextContentView(
                            text: text,
                            savedScrollY: scrollOffsetY,
                            highlightLine: highlightLine
                        )
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
/// returning preserves the position. When `nil`, the view simply starts at
/// the top.
///
/// `highlightLine` (1-based) marks a single line as the active match: that
/// line gets an accent-tinted background via `NSLayoutManager` temporary
/// attributes and the view auto-scrolls so the line lands at the viewport
/// center. Used by the content-search detail pane so clicking a match in
/// the sidebar lands the user on the matched line. When set on initial
/// load it overrides `savedScrollY` — the user wants to see the match,
/// not the previous reading position.
///
/// Backed by `NSTextView` so multi-line text selection (drag, cmd-A,
/// cmd-shift-arrow) and cmd-F find work natively. The line-number gutter
/// is a custom `NSRulerView` subclass that walks the layout manager's
/// line fragments at draw time.
private struct PlainTextContentView: NSViewRepresentable {
    let text: String
    var savedScrollY: Binding<CGFloat>?
    var highlightLine: Int?

    @MainActor
    final class Coordinator {
        var savedScrollY: Binding<CGFloat>?
        var lastAppliedText: String?
        var lastAppliedHighlight: Int?
        var observer: NSObjectProtocol?
        weak var observedClipView: NSClipView?
        /// Suppresses the bounds-changed observer while we programmatically
        /// scroll (initial restore, scroll-to-match), so the saved offset
        /// doesn't get stomped with the intermediate values the framework
        /// reports during the restore.
        var isRestoring = false

        func detachObserver() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            observedClipView = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // `scrollableTextView()` is Apple's canonical NSTextView setup —
        // wires up the layout manager, text container, autoresizing, and
        // initial sizing so the text view is immediately ready to render
        // when added to the view hierarchy. Hand-rolling the same setup
        // produced a (0, 0) text container before SwiftUI installed the
        // view, which left the document area unable to lay out glyphs.
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = text

        // Attach the line-number gutter. Sized at construction; we recompute
        // the width whenever the text changes so growing files (more digits)
        // don't push line numbers off the edge.
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.savedScrollY = savedScrollY
        context.coordinator.lastAppliedText = text
        context.coordinator.lastAppliedHighlight = highlightLine

        // Initial layout & scroll has to wait one runloop tick: textContainer
        // sizing and glyph generation haven't happened yet, so a synchronous
        // scrollRangeToVisible would clamp to (0, 0).
        let initialLine = highlightLine
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            attachClipObserver(scrollView: scrollView, coordinator: coordinator)
            apply(
                textView: textView,
                scrollView: scrollView,
                coordinator: coordinator,
                highlightLine: initialLine
            )
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.savedScrollY = savedScrollY

        let textChanged = context.coordinator.lastAppliedText != text
        let highlightChanged = context.coordinator.lastAppliedHighlight != highlightLine
        guard textChanged || highlightChanged else { return }

        if textChanged {
            textView.string = text
            (scrollView.verticalRulerView as? LineNumberRulerView)?.invalidateLineCount()
            context.coordinator.lastAppliedText = text
        }
        context.coordinator.lastAppliedHighlight = highlightLine

        // Defer the highlight + scroll mutations until SwiftUI finishes
        // its current update pass. Doing them synchronously inside
        // `updateNSView` interleaves with SwiftUI's layout/draw cycle and
        // leaves the window's other layer-backed surfaces (tab bar,
        // sidebar) in an unrendered state until the next input event.
        let line = highlightLine
        DispatchQueue.main.async { [coordinator = context.coordinator] in
            apply(
                textView: textView,
                scrollView: scrollView,
                coordinator: coordinator,
                highlightLine: line
            )
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.detachObserver()
    }

    /// Wires the clip-view bounds observer that mirrors user scrolls back
    /// into `savedScrollY`. The observer is suppressed while the view is
    /// programmatically scrolling so initial-restore / scroll-to-match
    /// don't clobber the saved offset.
    private func attachClipObserver(scrollView: NSScrollView, coordinator: Coordinator) {
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
            MainActor.assumeIsolated {
                guard let coordinator, let clip else { return }
                guard !coordinator.isRestoring else { return }
                coordinator.savedScrollY?.wrappedValue = clip.bounds.origin.y
            }
        }
    }

    /// Applies the requested `highlightLine` to the live NSTextView and
    /// scrolls so the line lands at the viewport center. Falls back to
    /// restoring the saved Y offset when no line is highlighted (initial
    /// attach for tabs / non-search file selection). Always invoked from
    /// the next runloop tick so we don't interleave with SwiftUI's layout
    /// pass.
    private func apply(
        textView: NSTextView,
        scrollView: NSScrollView,
        coordinator: Coordinator,
        highlightLine: Int?
    ) {
        applyHighlight(textView: textView, line: highlightLine)
        coordinator.isRestoring = true
        defer {
            // Release the suppression on the next runloop tick so any
            // bounds-changed notifications triggered by the scroll have
            // fired before we accept user-scroll updates again.
            DispatchQueue.main.async { coordinator.isRestoring = false }
        }
        if let line = highlightLine {
            centerScroll(textView: textView, scrollView: scrollView, line: line)
        } else if let savedY = coordinator.savedScrollY?.wrappedValue, savedY > 0 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: savedY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Adds an accent-tinted background to the matched line via the layout
    /// manager's temporary-attribute store. Temporary attributes don't
    /// affect the underlying string (so cmd-A copy still produces clean
    /// text) and are cheap to update — perfect for a transient highlight.
    private func applyHighlight(textView: NSTextView, line: Int?) {
        guard let layoutManager = textView.layoutManager else { return }
        let nsString = textView.string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        guard let line, let lineRange = lineCharacterRange(in: nsString, line: line) else { return }
        let highlight = NSColor.controlAccentColor.withAlphaComponent(0.22)
        layoutManager.addTemporaryAttribute(.backgroundColor, value: highlight, forCharacterRange: lineRange)
    }

    /// Scrolls so the requested line sits at the vertical center of the
    /// viewport. Falls back to a top-anchored position when the line is too
    /// near the start of the document to center cleanly. Called from a
    /// deferred async block so SwiftUI's layout pass can finish first;
    /// scrolling synchronously while SwiftUI is mid-update was leaving
    /// other layer-backed surfaces (tab bar, sidebar) unrendered.
    private func centerScroll(
        textView: NSTextView,
        scrollView: NSScrollView,
        line: Int
    ) {
        guard
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else { return }
        let nsString = textView.string as NSString
        guard let lineRange = lineCharacterRange(in: nsString, line: line) else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let viewportHeight = scrollView.contentView.bounds.height
        let inset = textView.textContainerInset.height
        var targetY = (lineRect.midY + inset) - viewportHeight / 2
        targetY = max(0, targetY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Resolves the (1-based) `line` to a character range in `nsString`.
    /// Returns `nil` if the file has fewer lines than requested.
    private func lineCharacterRange(in nsString: NSString, line: Int) -> NSRange? {
        guard line >= 1 else { return nil }
        var currentLine = 1
        var charIndex = 0
        let length = nsString.length
        while charIndex <= length {
            let range = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
            if currentLine == line {
                return range
            }
            currentLine += 1
            let next = NSMaxRange(range)
            if next == charIndex { break }
            charIndex = next
        }
        return nil
    }
}

// MARK: - Line Number Ruler View

/// Custom `NSRulerView` that draws 1-based line numbers next to the
/// matching lines of an attached `NSTextView`. Walks the layout manager's
/// glyph ranges at draw time so the gutter stays aligned with the text
/// view's actual line breaks (including soft-wrapping).
final private class LineNumberRulerView: NSRulerView {
    private static let labelFont: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let horizontalPadding: CGFloat = 8

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        invalidateLineCount()

        // Re-measure (and redraw) when the document changes so the gutter
        // grows to fit larger line numbers.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc
    private func textDidChange(_ notification: Notification) {
        invalidateLineCount()
    }

    /// Recomputes `ruleThickness` from the digit count of the largest line
    /// number, then asks AppKit to redraw. Idempotent — safe to call from
    /// the text-change notification and the SwiftUI update path.
    func invalidateLineCount() {
        guard let textView = clientView as? NSTextView else { return }
        let lineCount = (textView.string as NSString).numberOfLines()
        let digits = String(max(lineCount, 1)).count
        let sample = String(repeating: "0", count: digits) as NSString
        let labelWidth = sample.size(withAttributes: [.font: Self.labelFont]).width
        ruleThickness = max(36, labelWidth + Self.horizontalPadding * 2)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard
            let textView = clientView as? NSTextView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else {
            return
        }

        // Background + trailing separator so the gutter reads as a
        // distinct strip rather than blending into the text.
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: rect.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: rect.maxY))
        separator.lineWidth = 1
        separator.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        let nsString = textView.string as NSString
        guard nsString.length > 0 else { return }
        let yInset = textView.textContainerInset.height
        let visibleRect = textView.visibleRect

        // Restrict iteration to the visible glyph range — drawing every
        // line number for a 25k-line file would be wasteful and slow.
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        // Compute the line number at the start of the visible range. This
        // is O(visibleStart) which is bounded by the scroll position — for
        // typical source files, fast enough to redo every draw pass.
        var lineNumber = 1
        nsString.enumerateSubstrings(
            in: NSRange(location: 0, length: visibleCharRange.location),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in
            lineNumber += 1
        }

        let lastVisibleChar = min(NSMaxRange(visibleCharRange), nsString.length)
        var charIndex = nsString.lineRange(for: NSRange(location: visibleCharRange.location, length: 0)).location
        while charIndex < lastVisibleChar {
            let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

            // Translate from text-view coordinates (which are scrolled by
            // the scroll view) to the ruler's own coordinate space, which
            // shares the scrollView's clip-view origin.
            let y = lineRect.origin.y + yInset - visibleRect.origin.y

            let label = "\(lineNumber)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            let labelRect = NSRect(
                x: bounds.maxX - labelSize.width - Self.horizontalPadding,
                y: y + (lineRect.height - labelSize.height) / 2,
                width: labelSize.width,
                height: labelSize.height
            )
            label.draw(in: labelRect, withAttributes: attributes)

            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next == charIndex { break }
            charIndex = next
        }
    }
}

private extension NSString {
    /// Counts hard line breaks. Used to size the line-number gutter.
    /// `enumerateSubstrings(options: .byLines)` skips the trailing empty
    /// line for a file ending in `\n`, matching Xcode/VS Code behavior
    /// (the "phantom" trailing line isn't numbered).
    func numberOfLines() -> Int {
        guard length > 0 else { return 0 }
        var count = 0
        enumerateSubstrings(
            in: NSRange(location: 0, length: length),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in
            count += 1
        }
        return max(count, 1)
    }
}
