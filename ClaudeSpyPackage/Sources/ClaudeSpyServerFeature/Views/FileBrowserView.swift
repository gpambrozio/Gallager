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

/// A file opened as its own tab to the right of the file explorer tab.
/// Identified by a stable UUID so re-opens select the existing tab and
/// deletion state can be tracked without losing the tab.
///
/// `directoryPath` is the file-browser root that originated the tab; the path
/// header renders relative to this so the displayed path stays stable when the
/// user switches to a sibling tmux window with a different cwd.
struct OpenFileTab: Identifiable, Equatable {
    let id: UUID
    let path: String
    let directoryPath: String
    var isDeleted: Bool

    init(id: UUID = UUID(), path: String, directoryPath: String, isDeleted: Bool = false) {
        self.id = id
        self.path = path
        self.directoryPath = directoryPath
        self.isDeleted = isDeleted
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
    /// All files under the directory, cached for search.
    var allFiles: [FileSearchResult] = []
    /// The directory path for which `allFiles` was loaded.
    var allFilesDirectoryPath: String?
    /// Current search query, preserved across tab switches.
    var searchQuery = ""
    /// Selected file path in search results, preserved across tab switches.
    var selectedSearchPath: String?
    /// Cached search results matching the current query.
    var cachedSearchResults: [FileSearchResult] = []
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

    @State private var loadTreeTask: Task<Void, Never>?

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
            OpenFileTabContentView(tab: tab)
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
            }
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

            TextField("Search files...", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.callout)
                .accessibilityLabel("Search files")

            if !state.searchQuery.isEmpty {
                Button {
                    state.searchQuery = ""
                    state.selectedSearchPath = nil
                } label: {
                    Symbols.xmarkCircleFill.image
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
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
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func searchResultRow(_ result: FileSearchResult) -> some View {
        let directory: String = {
            guard let lastSlash = result.relativePath.lastIndex(of: "/") else { return "" }
            return String(result.relativePath[..<lastSlash])
        }()

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

    private func fileRowLabel(name: String, itemId: UUID) -> some View {
        Label {
            Text(name)
                .font(.callout)
        } icon: {
            Symbols.docPlaintextFill.image
                .foregroundStyle(.secondary)
        }
        .fileTreeContextMenu(
            itemId: itemId,
            directoryPath: directoryPath,
            reverseIds: state.reverseIds,
            isDirectory: false,
            onOpenFileInNewTab: onOpenFileInNewTab
        )
    }

    private func folderRowLabel(name: String, itemId: UUID) -> some View {
        Label {
            Text(name)
                .font(.callout)
        } icon: {
            Symbols.folderFill.image
                .foregroundStyle(.blue)
        }
        .fileTreeContextMenu(
            itemId: itemId,
            directoryPath: directoryPath,
            reverseIds: state.reverseIds,
            isDirectory: true,
            onOpenFileInNewTab: onOpenFileInNewTab
        )
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
                            fileLabel: { cursor, _, proxy in
                                fileRowLabel(name: cursor.name, itemId: proxy.id)
                            },
                            folderLabel: { cursor, _, folder in
                                folderRowLabel(name: cursor.name, itemId: folder.wrappedValue.id)
                            }
                        )
                        .navigatorFilter { !skippedNavigatorEntries.contains($0) }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                } else {
                    fileSearchResultsList
                }
            }
            .frame(width: state.sidebarWidth)

            ResizableDivider(dimension: $state.sidebarWidth, minDimension: 150, maxDimension: 400)

            fileDetailView(viewState: viewState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: state.searchQuery, initial: true) {
            recomputeSearchResults()
        }
        .onChange(of: state.allFiles) {
            recomputeSearchResults()
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
    }

    @ViewBuilder
    private func fileDetailView(
        viewState: FileNavigatorViewState<TextFileContents>
    ) -> some View {
        if !state.searchQuery.isEmpty {
            if let path = state.selectedSearchPath {
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
                    LiveFileContentView(filePath: path)
                }
            } else {
                ContentUnavailableView(
                    "Search for Files",
                    symbol: .magnifyingglass,
                    description: "Type a file name to search, then select a result to view."
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
                    LiveFileContentView(filePath: fullFilePath)
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
}

// MARK: - File Tree Context Menu

private extension View {
    func fileTreeContextMenu(
        itemId: UUID,
        directoryPath: String,
        reverseIds: [UUID: String],
        isDirectory: Bool,
        onOpenFileInNewTab: @escaping (String) -> Void
    ) -> some View {
        let fullPath = reverseIds[itemId]
        let relativePath = fullPath.map { String($0.dropFirst(directoryPath.count + 1)) }

        return contextMenu {
            if let fullPath {
                Button("Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: fullPath))
                }
                if !isDirectory {
                    Button("Open in New Tab") {
                        onOpenFileInNewTab(fullPath)
                    }
                }
                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fullPath)])
                }
                Divider()
                Button("Copy Path") {
                    @Dependency(ClipboardClient.self) var clipboard
                    clipboard.setString(fullPath)
                }
                if let relativePath {
                    Button("Copy Relative Path") {
                        @Dependency(ClipboardClient.self) var clipboard
                        clipboard.setString(relativePath)
                    }
                }
                if !isDirectory {
                    Button("Copy") {
                        @Dependency(ClipboardClient.self) var clipboard
                        clipboard.setFileURL(URL(fileURLWithPath: fullPath))
                    }
                }
            }
        }
    }
}

// MARK: - Open File Tab Content View

/// The content view shown when the user selects an open file tab.
/// Renders the file's path header + live content, or a "file deleted" placeholder.
struct OpenFileTabContentView: View {
    let tab: OpenFileTab

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
                LiveFileContentView(filePath: tab.path)
            }
        }
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
private struct LiveFileContentView: View {
    let filePath: String

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
                    PDFViewRepresentable(url: fileSystemService.resolveFileURL(filePath) ?? URL(fileURLWithPath: filePath))
                case .video:
                    AVPlayerViewRepresentable(url: fileSystemService.resolveFileURL(filePath) ?? URL(fileURLWithPath: filePath))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .html:
                    if #available(macOS 26, *) {
                        WebView(url: fileSystemService.resolveFileURL(filePath) ?? URL(fileURLWithPath: filePath))
                    }
                case .markdown:
                    if let text {
                        MarkdownContentView(text: text)
                    }
                case .text:
                    if let text {
                        TextEditor(text: .constant(text))
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
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
private struct PDFViewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
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
/// The `.task` nudges the scroll offset (y: 4 → 0) to reproduce that manual scroll, and the
/// `minHeight` pegged to the container guarantees the content is always taller than the
/// viewport so the nudge actually moves the offset — even for markdown short enough to fit
/// without scrolling. Remove all of this once the upstream issue is fixed.
private struct MarkdownContentView: View {
    let text: String
    @State private var scrollPosition = ScrollPosition(edge: .top)

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
            .textual.textSelection(.enabled)
            .task(id: text) {
                try? await Task.sleep(for: .milliseconds(100))
                scrollPosition.scrollTo(y: 4)
                try? await Task.sleep(for: .milliseconds(50))
                scrollPosition.scrollTo(y: 0)
            }
        }
    }
}
