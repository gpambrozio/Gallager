import AppKit
import ClaudeSpyCommon
import Files
import ProjectNavigator
import SwiftUI

private let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico", "svg",
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
    var stableIds: [String: UUID] = [:]
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
        let result = await loadFileTree(
            at: URL(fileURLWithPath: directoryPath),
            expandedPaths: state.loadedFolderPaths,
            stableIds: state.stableIds
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
        // Find expanded folder UUIDs that aren't loaded yet
        let reverseIds = Dictionary(state.stableIds.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        for expandedId in viewState.expansions.ids {
            guard let path = reverseIds[expandedId] else { continue }
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
                    fileLabel: { cursor, _, _ in
                        Label {
                            Text(cursor.name)
                                .font(.callout)
                        } icon: {
                            Symbols.docPlaintextFill.image
                                .foregroundStyle(.secondary)
                        }
                    },
                    folderLabel: { cursor, _, _ in
                        Label {
                            Text(cursor.name)
                                .font(.callout)
                        } icon: {
                            Symbols.folderFill.image
                                .foregroundStyle(.blue)
                        }
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

// MARK: - Live File Content View

/// Displays a file's contents and monitors it for changes on disk.
/// Text files are shown in a text editor, images are shown scaled to fit.
private struct LiveFileContentView: View {
    let filePath: String

    @State private var isImage: Bool
    @State private var text: String?
    @State private var nsImage: NSImage?

    init(filePath: String) {
        self.filePath = filePath
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        let imageFile = imageExtensions.contains(ext)
        _isImage = State(initialValue: imageFile)
        // Load content synchronously so the first frame is never empty
        if imageFile {
            _nsImage = State(initialValue: NSImage(contentsOfFile: filePath))
        } else {
            _text = State(initialValue: try? String(contentsOfFile: filePath, encoding: .utf8))
        }
    }

    var body: some View {
        Group {
            if isImage, let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else if let text {
                TextEditor(text: .constant(text))
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
            } else {
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
            for await _ in fileChanges(at: filePath) {
                loadContent()
            }
        }
    }

    private func loadContent() {
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        isImage = imageExtensions.contains(ext)
        if isImage {
            nsImage = NSImage(contentsOfFile: filePath)
            text = nil
        } else {
            text = try? String(contentsOfFile: filePath, encoding: .utf8)
            nsImage = nil
        }
    }
}

/// Returns an `AsyncStream` that yields a value each time the file at `path` is modified.
private func fileChanges(at path: String) -> AsyncStream<Void> {
    AsyncStream { continuation in
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            continuation.finish()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )

        source.setEventHandler {
            continuation.yield()
        }

        source.setCancelHandler {
            close(fd)
        }

        continuation.onTermination = { _ in
            source.cancel()
        }

        source.resume()
    }
}
