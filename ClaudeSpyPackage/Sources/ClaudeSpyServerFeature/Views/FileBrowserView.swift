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
}

/// A draggable vertical divider for resizing adjacent views.
private struct ResizableDivider: View {
    @Binding var dimension: CGFloat
    let minDimension: CGFloat
    let maxDimension: CGFloat

    @State private var isDragging = false
    @State private var initialDimension: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color.gray.opacity(0.3))
            .frame(width: 4)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
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

    var body: some View {
        if let viewState = state.viewState {
            fileBrowserContent(viewState: viewState)
                .task(id: directoryPath) {
                    guard state.loadedPath != directoryPath else { return }
                    await loadTree()
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

    @ViewBuilder
    private func fileBrowserContent(
        viewState: FileNavigatorViewState<TextFileContents>
    ) -> some View {
        @Bindable var bindableState = viewState
        let directoryName = URL(fileURLWithPath: directoryPath).lastPathComponent

        HStack(spacing: 0) {
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
                .navigatorFilter { $0.first != "." }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: state.sidebarWidth)

            ResizableDivider(dimension: $state.sidebarWidth, minDimension: 150, maxDimension: 400)

            fileDetailView(viewState: viewState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func fileDetailView(
        viewState: FileNavigatorViewState<TextFileContents>
    ) -> some View {
        if
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

    @State private var kind: FileContentKind
    @State private var text: String?
    @State private var nsImage: NSImage?

    init(filePath: String) {
        self.filePath = filePath
        @Dependency(FileSystemLoadingService.self) var service
        let detectedKind = service.detectFileKind(filePath)
        _kind = State(initialValue: detectedKind)
        switch detectedKind {
        case .image:
            _nsImage = State(initialValue: service.readImageFile(filePath))
        case .markdown,
             .text:
            _text = State(initialValue: service.readTextFile(filePath))
        default:
            break
        }
    }

    var body: some View {
        Group {
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
        .task(id: filePath) {
            loadContent()
            for await _ in fileSystemService.fileChanges(filePath) {
                loadContent()
            }
        }
    }

    private func loadContent() {
        kind = fileSystemService.detectFileKind(filePath)
        // Clear all state first
        text = nil
        nsImage = nil

        switch kind {
        case .image:
            nsImage = fileSystemService.readImageFile(filePath)
        case .markdown,
             .text:
            text = fileSystemService.readTextFile(filePath)
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
