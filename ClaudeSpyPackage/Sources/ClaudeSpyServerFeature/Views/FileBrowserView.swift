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
private let skippedNavigatorEntries: Set<String> = [
    ".DS_Store", ".Trash", ".Spotlight-V100", ".fseventsd",
    ".TemporaryItems", ".DocumentRevisions-V100",
]

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

    @Dependency(FileSystemLoadingService.self) private var fileSystemService

    @State private var searchQuery = ""
    @State private var selectedSearchPath: String?

    var body: some View {
        if let viewState = state.viewState {
            fileBrowserContent(viewState: viewState)
                .task(id: directoryPath) {
                    if state.loadedPath != directoryPath {
                        await loadTree()
                    }
                    if state.allFilesDirectoryPath != directoryPath {
                        state.allFiles = await fileSystemService.collectAllFiles(
                            URL(fileURLWithPath: directoryPath)
                        )
                        state.allFilesDirectoryPath = directoryPath
                    }
                }
                .task(id: state.loadedFolderPaths) {
                    var watchedPaths = state.loadedFolderPaths
                    watchedPaths.insert(directoryPath)
                    for await _ in fileSystemService.directoryChanges(watchedPaths) {
                        await loadTree()
                        state.allFiles = await fileSystemService.collectAllFiles(
                            URL(fileURLWithPath: directoryPath)
                        )
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
                    state.allFiles = await fileSystemService.collectAllFiles(
                        URL(fileURLWithPath: directoryPath)
                    )
                    state.allFilesDirectoryPath = directoryPath
                }
        }
    }

    private func loadTree() async {
        let result = await fileSystemService.loadFileTree(
            URL(fileURLWithPath: directoryPath),
            state.loadedFolderPaths,
            state.stableIds
        )
        let tree = FileTree(files: result.root)
        let expansions: WrappedUUIDSet
        let selection: FileOrFolder.ID?
        if let existing = state.viewState {
            // Preserve expansion and selection state across rebuilds
            expansions = existing.expansions
            selection = existing.selection
        } else {
            expansions = WrappedUUIDSet()
            selection = nil
        }
        let viewState = FileNavigatorViewState<TextFileContents>(
            fileTree: tree,
            expansions: expansions,
            selection: selection
        )
        // Expand the root folder by default
        viewState.expansions[tree.root.id] = true
        state.viewState = viewState
        state.loadedPath = directoryPath
        state.stableIds = result.stableIds
        state.loadedFolderPaths = result.loadedFolderPaths
    }

    /// Detects when the user expands a folder whose children haven't been loaded yet,
    /// and triggers a tree rebuild with that folder's contents.
    private func handleExpansionChange(viewState: FileNavigatorViewState<TextFileContents>) {
        for expandedId in viewState.expansions.ids {
            guard let path = state.reverseIds[expandedId] else { continue }
            guard !state.loadedFolderPaths.contains(path) else { continue }

            // This folder needs its children loaded
            state.loadedFolderPaths.insert(path)
            Task {
                await loadTree()
            }
            return
        }
    }

    // MARK: - File Search

    @ViewBuilder
    private var fileSearchField: some View {
        HStack(spacing: 6) {
            Symbols.magnifyingglass.image
                .foregroundStyle(.secondary)
                .font(.caption)

            TextField("Search files...", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.callout)
                .accessibilityLabel("Search files")

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    selectedSearchPath = nil
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

    private var filteredSearchResults: [FileSearchResult] {
        guard !searchQuery.isEmpty else { return [] }
        let query = searchQuery

        return Array(
            state.allFiles
                .compactMap { result -> (FileSearchResult, Int)? in
                    guard result.relativePath.fuzzyMatches(query) else { return nil }
                    return (result, fileSearchScore(for: result, query: query))
                }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return lhs.0.relativePath.count < rhs.0.relativePath.count
                }
                .prefix(100)
                .map(\.0)
        )
    }

    private func fileSearchScore(for result: FileSearchResult, query: String) -> Int {
        let name = result.name.lowercased()
        let q = query.lowercased()
        if name == q { return 4 }
        if name.hasPrefix(q) { return 3 }
        if name.contains(q) { return 2 }
        if name.fuzzyMatches(q) { return 1 }
        return 0
    }

    @ViewBuilder
    private var fileSearchResultsList: some View {
        let results = filteredSearchResults
        if results.isEmpty {
            ContentUnavailableView.search(text: searchQuery)
        } else {
            List(selection: $selectedSearchPath) {
                ForEach(results) { result in
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
        let directory = (result.relativePath as NSString).deletingLastPathComponent

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

    @ViewBuilder
    private func fileBrowserContent(
        viewState: FileNavigatorViewState<TextFileContents>
    ) -> some View {
        @Bindable var bindableState = viewState
        let directoryName = URL(fileURLWithPath: directoryPath).lastPathComponent

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                fileSearchField
                Divider()

                if searchQuery.isEmpty {
                    List(selection: $bindableState.selection) {
                        FileNavigator(
                            name: directoryName,
                            item: .constant(viewState.fileTree.root),
                            parent: .constant(nil),
                            viewState: viewState,
                            fileLabel: { cursor, _, proxy in
                                Label {
                                    Text(cursor.name)
                                        .font(.callout)
                                } icon: {
                                    Symbols.docPlaintextFill.image
                                        .foregroundStyle(.secondary)
                                }
                                .fileTreeContextMenu(
                                    itemId: proxy.id,
                                    directoryPath: directoryPath,
                                    reverseIds: state.reverseIds
                                )
                            },
                            folderLabel: { cursor, _, folder in
                                Label {
                                    Text(cursor.name)
                                        .font(.callout)
                                } icon: {
                                    Symbols.folderFill.image
                                        .foregroundStyle(.blue)
                                }
                                .fileTreeContextMenu(
                                    itemId: folder.wrappedValue.id,
                                    directoryPath: directoryPath,
                                    reverseIds: state.reverseIds
                                )
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
        .onChange(of: searchQuery) {
            selectedSearchPath = nil
        }
    }

    @ViewBuilder
    private func fileDetailView(
        viewState: FileNavigatorViewState<TextFileContents>
    ) -> some View {
        if !searchQuery.isEmpty {
            if let path = selectedSearchPath {
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
        reverseIds: [UUID: String]
    ) -> some View {
        let fullPath = reverseIds[itemId]
        let relativePath = fullPath.map { String($0.dropFirst(directoryPath.count + 1)) }

        return contextMenu {
            if let fullPath {
                Button("Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: fullPath))
                }
                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fullPath)])
                }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullPath, forType: .string)
                }
                if let relativePath {
                    Button("Copy Relative Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(relativePath, forType: .string)
                    }
                }
                let isDirectory = (try? URL(fileURLWithPath: fullPath)
                    .resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if !isDirectory {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([URL(fileURLWithPath: fullPath) as NSURL])
                    }
                }
            }
        }
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
                        ScrollView {
                            StructuredText(markdown: text)
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
